"""Anthropic OAuth plan-usage fetcher (CodexBar-equivalent).

Reads the Claude Code OAuth token from macOS Keychain
(`Claude Code-credentials`) or `~/.claude/.credentials.json`, calls
`GET https://api.anthropic.com/api/oauth/usage`, and returns session/weekly
utilization + reset times. Refreshes the access token when expired/401 and
writes it back to the same credential store — through the Security framework
(see keychain.py), never through `security -w`, which would expose the token
in the process table.

Stdlib only. The endpoint is undocumented and may change; failures degrade
to an empty quota dict so the desk gadget still shows local cost data.
"""

from __future__ import annotations

import json
import os
import subprocess
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

import cache_util
import keychain

USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
TOKEN_URLS = (
    "https://platform.claude.com/v1/oauth/token",
    "https://console.anthropic.com/v1/oauth/token",
)
CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
OAUTH_BETA = "oauth-2025-04-20"
UA = "claude-cli/2.1.201 (external, cli)"
CREDS_FILE = os.path.expanduser("~/.claude/.credentials.json")
KEYCHAIN_SERVICE = "Claude Code-credentials"
CACHE_TTL_S = 60
FAIL_TTL_S = 20          # retry sooner after transient misses (429, etc.)
EXPIRY_SKEW_S = 120

_cache = {"t": 0.0, "data": None, "err": None}


def _keychain_account():
    try:
        out = subprocess.check_output(
            ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE],
            stderr=subprocess.DEVNULL, text=True,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None
    for line in out.splitlines():
        line = line.strip()
        if line.startswith('"acct"'):
            # "acct"<blob>="mz"
            i = line.find('="')
            if i >= 0:
                return line[i + 2:].rstrip('"')
    return os.environ.get("USER") or os.environ.get("LOGNAME")


def _read_creds_blob():
    """Return (store, blob_dict) where store is 'keychain'|'file'|None."""
    try:
        raw = subprocess.check_output(
            ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
            stderr=subprocess.DEVNULL, text=True,
        ).strip()
        if raw:
            return "keychain", json.loads(raw)
    except (subprocess.CalledProcessError, FileNotFoundError, json.JSONDecodeError):
        pass
    try:
        with open(CREDS_FILE) as f:
            return "file", json.load(f)
    except (OSError, json.JSONDecodeError):
        return None, None


def _write_creds_blob(store, blob):
    raw = json.dumps(blob, separators=(",", ":"))
    if store == "keychain":
        acct = _keychain_account() or "Claude"
        # Via the Security framework, not `security -w`, which would put the
        # refresh token in argv where any process can read it out of `ps`.
        keychain.set_generic_password(KEYCHAIN_SERVICE, acct, raw)
        return
    tmp = CREDS_FILE + ".tmp"
    with open(tmp, "w") as f:
        f.write(raw)
    os.chmod(tmp, 0o600)
    os.replace(tmp, CREDS_FILE)


def _oauth_block(blob):
    o = (blob or {}).get("claudeAiOauth") or {}
    if not o.get("accessToken"):
        return None
    return o


def _expires_at_s(oauth):
    ms = oauth.get("expiresAt")
    if not isinstance(ms, (int, float)):
        return None
    return ms / 1000.0 if ms > 1e12 else float(ms)


def _needs_refresh(oauth):
    exp = _expires_at_s(oauth)
    if exp is None:
        return False
    return exp - time.time() <= EXPIRY_SKEW_S


def _refresh(oauth, store, blob):
    refresh = oauth.get("refreshToken")
    if not refresh:
        raise RuntimeError("no refreshToken")
    body = json.dumps({
        "grant_type": "refresh_token",
        "refresh_token": refresh,
        "client_id": CLIENT_ID,
    }).encode()
    last_err = None
    for url in TOKEN_URLS:
        req = urllib.request.Request(
            url, data=body, method="POST",
            headers={
                "Content-Type": "application/json",
                "User-Agent": UA,
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = json.loads(resp.read().decode())
        except urllib.error.HTTPError as e:
            last_err = f"HTTP {e.code} from {url}"
            continue
        except Exception as e:
            last_err = str(e)
            continue
        access = data.get("access_token")
        if not access:
            last_err = "refresh response missing access_token"
            continue
        oauth["accessToken"] = access
        if data.get("refresh_token"):
            oauth["refreshToken"] = data["refresh_token"]
        expires_in = data.get("expires_in")
        if isinstance(expires_in, (int, float)):
            oauth["expiresAt"] = int((time.time() + expires_in) * 1000)
        blob["claudeAiOauth"] = oauth
        try:
            _write_creds_blob(store, blob)
        except Exception as exc:
            # Persisting failed (locked Keychain, read-only home). The token in
            # hand is still good for this process — don't throw the refresh away.
            print("oauth: could not persist refreshed token:", exc)
        return oauth
    raise RuntimeError(last_err or "token refresh failed")


def _http_get_usage(token):
    req = urllib.request.Request(
        USAGE_URL,
        headers={
            "Authorization": f"Bearer {token}",
            "User-Agent": UA,
            "Accept": "application/json",
            "anthropic-beta": OAUTH_BETA,
            "anthropic-version": "2023-06-01",
            "x-app": "cli",
        },
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        return resp.getcode(), json.loads(resp.read().decode())


def _iso_to_unix(s):
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def _window_from_flat(obj):
    if not isinstance(obj, dict):
        return None
    util = obj.get("utilization")
    if util is None:
        return None
    resets = _iso_to_unix(obj.get("resets_at"))
    return {
        "pct": round(float(util), 1),
        "resets_at": obj.get("resets_at"),
        "resets_in_s": max(0, int(resets - time.time())) if resets else None,
    }


def _window_from_limit(lim):
    if not isinstance(lim, dict):
        return None
    pct = lim.get("percent")
    if pct is None:
        return None
    resets = _iso_to_unix(lim.get("resets_at"))
    return {
        "pct": round(float(pct), 1),
        "resets_at": lim.get("resets_at"),
        "resets_in_s": max(0, int(resets - time.time())) if resets else None,
    }


def _prettify_tier(raw):
    if not raw:
        return None
    s = raw.strip()
    if s.startswith("default_"):
        s = s[len("default_"):]
    if s.startswith("claude_"):
        s = s[len("claude_"):]
    s = s.replace("_", " ")
    parts = s.split()
    if parts:
        parts[0] = parts[0].capitalize()
    return " ".join(parts)


def parse_usage(body, oauth=None):
    """Map API JSON → flat quota dict for /usage."""
    out = {
        "ok": True,
        "plan": _prettify_tier(
            (oauth or {}).get("rateLimitTier")
            or (oauth or {}).get("subscriptionType")
        ),
        "session": None,
        "week": None,
    }

    # Newer shape: limits[]
    limits = body.get("limits")
    if isinstance(limits, list) and limits:
        session = next((l for l in limits if l.get("kind") == "session"), None)
        week = next((l for l in limits if l.get("kind") == "weekly_all"), None)
        if week is None:
            # fall back to highest weekly_* 
            weeklies = [l for l in limits if str(l.get("kind", "")).startswith("weekly")]
            if weeklies:
                week = max(weeklies, key=lambda l: float(l.get("percent") or 0))
        out["session"] = _window_from_limit(session)
        out["week"] = _window_from_limit(week)
        return out

    # Classic flat keys
    out["session"] = _window_from_flat(body.get("five_hour"))
    out["week"] = _window_from_flat(body.get("seven_day"))
    return out


def fetch_quota(force=False):
    """Return quota dict, using a short in-memory cache. Never raises."""
    now = time.time()
    if _cache["data"] is None:
        disk = cache_util.load_disk("claude")
        if disk:
            _cache.update(t=0.0, data=disk, err=None)
    if not force and _cache["data"] is not None:
        ttl = CACHE_TTL_S if _cache["data"].get("ok") else FAIL_TTL_S
        if now - _cache["t"] < ttl:
            return _cache["data"]

    empty = {"ok": False, "plan": None, "session": None, "week": None, "error": None}

    def _keep_stale(err):
        return cache_util.keep_stale(
            _cache, now, err, empty, disk_name="claude")

    try:
        store, blob = _read_creds_blob()
        if not store:
            return _keep_stale(
                "no Claude credentials (Keychain or ~/.claude/.credentials.json)")
        oauth = _oauth_block(blob)
        if not oauth:
            return _keep_stale("credentials missing claudeAiOauth.accessToken")

        if _needs_refresh(oauth):
            try:
                oauth = _refresh(oauth, store, blob)
            except Exception:
                # still try the current token; it might work
                pass

        try:
            status, body = _http_get_usage(oauth["accessToken"])
        except urllib.error.HTTPError as e:
            if e.code in (401, 403):
                oauth = _refresh(oauth, store, blob)
                status, body = _http_get_usage(oauth["accessToken"])
            else:
                # 429 / 5xx — keep last good bars instead of wiping the page.
                return _keep_stale(f"HTTP Error {e.code}: {e.reason}")

        if status != 200:
            return _keep_stale(f"usage HTTP {status}")

        data = parse_usage(body, oauth)
        data["stale"] = False
        data["error"] = None
        _cache.update(t=now, data=data, err=None)
        cache_util.save_disk("claude", data)
        return data
    except Exception as e:
        return _keep_stale(str(e))


def fmt_resets(seconds):
    """Match CodexBar-ish '1h 44m' / '4d 44m'."""
    if seconds is None:
        return None
    s = max(0, int(seconds))
    d, rem = divmod(s, 86400)
    h, rem = divmod(rem, 3600)
    m = rem // 60
    if d > 0:
        if h > 0:
            return f"{d}d {h}h"
        if m > 0:
            return f"{d}d {m}m"
        return f"{d}d"
    if h > 0:
        return f"{h}h {m}m" if m else f"{h}h"
    return f"{m}m"


# Rolling window lengths Anthropic uses for the OAuth buckets.
SESSION_WINDOW_S = 5 * 3600
WEEK_WINDOW_S = 7 * 24 * 3600


def pace_pct(resets_in_s, window_s):
    """Where a linear burn would be right now (0–100), given time left to reset."""
    if resets_in_s is None or window_s <= 0:
        return None
    elapsed = window_s - max(0, int(resets_in_s))
    if elapsed < 0:
        elapsed = 0
    if elapsed > window_s:
        elapsed = window_s
    return round(100.0 * elapsed / window_s, 1)
