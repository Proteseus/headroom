"""Gemini CLI / Code Assist quota via OAuth credentials.

Reads `~/.gemini/oauth_creds.json`, refreshes when needed, then calls
`retrieveUserQuota`. CodexBar-equivalent; consumer tiers may be deprecated.
"""

from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request

import http_util
import cache_util
import quota_util

CACHE_TTL_S = 60
FAIL_TTL_S = 20
DISK = "gemini_quota"
# A second Google login is a second Gemini CLI home holding the same two
# filenames — see accounts.py. Names live here because the fetcher owns them.
CREDS_NAME = "oauth_creds.json"
SETTINGS_NAME = "settings.json"
GEMINI_HOME = os.path.expanduser("~/.gemini")
CREDS_PATH = os.path.join(GEMINI_HOME, CREDS_NAME)
SETTINGS_PATH = os.path.join(GEMINI_HOME, SETTINGS_NAME)
QUOTA_URL = "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota"
TIER_URL = "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
TOKEN_URL = "https://oauth2.googleapis.com/token"
UA = "Headroom/1"
DAY_WINDOW_S = 24 * 3600

# One cache per account, keyed by account id ("" is the default login).
_cache = {"t": 0.0, "data": None, "err": None}
_caches = {"": _cache}
_EMPTY = {"ok": False, "plan": None, "pro": None, "flash": None}


def _cache_for(account):
    key = account.id if account else ""
    cache = _caches.get(key)
    if cache is None:
        cache = _caches[key] = {"t": 0.0, "data": None, "err": None}
    return cache


def _creds_path(account=None):
    return account.child(CREDS_NAME) if account else CREDS_PATH


def _settings_path(account=None):
    return account.child(SETTINGS_NAME) if account else SETTINGS_PATH


def signed_in():
    blob = _read_creds()
    return bool(blob and blob.get("access_token"))


def _oauth_client():
    """Return (client_id, client_secret) from env or installed Gemini CLI."""
    env_id = os.environ.get("GEMINI_OAUTH_CLIENT_ID")
    env_secret = os.environ.get("GEMINI_OAUTH_CLIENT_SECRET")
    if env_id and env_secret:
        return env_id, env_secret

    override = os.environ.get("GEMINI_OAUTH2_JS_PATH")
    candidates = []
    if override:
        candidates.append(override)
    candidates.extend((
        "/opt/homebrew/lib/node_modules/@google/gemini-cli/node_modules/"
        "@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
        "/usr/local/lib/node_modules/@google/gemini-cli/node_modules/"
        "@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
        "/opt/homebrew/opt/gemini-cli/libexec/lib/node_modules/@google/gemini-cli/"
        "node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
    ))
    import re
    for path in candidates:
        try:
            with open(path) as handle:
                text = handle.read()
        except OSError:
            continue
        cid = re.search(r'OAUTH_CLIENT_ID\s*=\s*["\']([^"\']+)["\']', text)
        secret = re.search(
            r'OAUTH_CLIENT_SECRET\s*=\s*["\']([^"\']+)["\']', text)
        if cid and secret:
            return cid.group(1), secret.group(1)
    return None, None


def _read_creds(account=None):
    try:
        with open(_creds_path(account)) as handle:
            blob = json.load(handle)
    except (OSError, json.JSONDecodeError, TypeError):
        return None
    return blob if isinstance(blob, dict) else None


def _write_creds(blob, account=None):
    path = _creds_path(account)
    raw = json.dumps(blob, indent=2)
    tmp = path + ".tmp"
    try:
        with open(tmp, "w") as handle:
            handle.write(raw)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except OSError:
        pass


def _auth_type(account=None):
    try:
        with open(_settings_path(account)) as handle:
            blob = json.load(handle)
    except (OSError, json.JSONDecodeError, TypeError):
        return "oauth-personal"
    return (blob or {}).get("selectedAuthType") or "oauth-personal"


def _refresh(blob, account=None):
    refresh = blob.get("refresh_token")
    if not refresh:
        raise RuntimeError("Gemini OAuth refresh_token missing")
    client_id, client_secret = _oauth_client()
    if not client_id or not client_secret:
        raise RuntimeError(
            "Gemini OAuth client not found — install gemini-cli or set "
            "GEMINI_OAUTH_CLIENT_ID/SECRET")
    token = http_util.request_json(
        TOKEN_URL,
        form_body={
            "client_id": client_id,
            "client_secret": client_secret,
            "refresh_token": refresh,
            "grant_type": "refresh_token",
        },
        user_agent=UA,
        timeout=12,
    )
    blob = dict(blob)
    if token.get("access_token"):
        blob["access_token"] = token["access_token"]
    if token.get("refresh_token"):
        blob["refresh_token"] = token["refresh_token"]
    if token.get("expires_in"):
        blob["expiry_date"] = int(
            (time.time() + float(token["expires_in"])) * 1000)
    _write_creds(blob, account)
    return blob


def _access_token(blob, account=None):
    expiry = blob.get("expiry_date")
    try:
        expiry_s = float(expiry) / 1000.0 if expiry else 0
    except (TypeError, ValueError):
        expiry_s = 0
    if expiry_s and expiry_s < time.time() + 60:
        blob = _refresh(blob, account)
    return blob.get("access_token"), blob


def _post_json(url, token, body):
    return http_util.request_json(
        url, auth=f"Bearer {token}", json_body=body,
        method="POST", user_agent=UA, timeout=12)


def _tier_label(blob, account=None):
    try:
        token, blob = _access_token(blob, account)
        if not token:
            return None, blob
        data = _post_json(
            TIER_URL, token,
            {"metadata": {"ideType": "GEMINI_CLI", "pluginType": "GEMINI"}},
        )
    except Exception:  # noqa: BLE001
        return None, blob
    paid = data.get("paidTier") if isinstance(data, dict) else None
    if isinstance(paid, list) and paid:
        name = (paid[0] or {}).get("name")
        if name:
            return str(name), blob
    current = (data.get("currentTier") or data.get("tier") or {})
    if isinstance(current, dict):
        tid = current.get("id") or current.get("name") or ""
    else:
        tid = str(current or "")
    mapping = {
        "standard-tier": "Paid",
        "free-tier": "Free",
        "legacy-tier": "Legacy",
    }
    return mapping.get(str(tid), str(tid).replace("-", " ").title() or None), blob


def _buckets(quota_blob):
    """Return (pro_pct, flash_pct, resets_in) from retrieveUserQuota."""
    buckets = []
    if isinstance(quota_blob, dict):
        for key in ("quotas", "buckets", "models", "tokenBudgets"):
            val = quota_blob.get(key)
            if isinstance(val, list):
                buckets = val
                break
        if not buckets and isinstance(quota_blob.get("quota"), list):
            buckets = quota_blob["quota"]
    pro = []
    flash = []
    resets = []
    for row in buckets:
        if not isinstance(row, dict):
            continue
        model = str(row.get("modelId") or row.get("model") or "").lower()
        frac = row.get("remainingFraction")
        if frac is None and row.get("remaining_fraction") is not None:
            frac = row.get("remaining_fraction")
        pct = None
        if frac is not None:
            try:
                pct = quota_util.remaining_pct_to_used(float(frac) * 100.0)
            except (TypeError, ValueError):
                pct = None
        if pct is None:
            pct = quota_util.used_pct(row.get("used"), row.get("limit"))
        if pct is None:
            continue
        reset = quota_util.resets_from_iso(
            row.get("resetTime") or row.get("reset_time"))
        if reset is not None:
            resets.append(reset)
        if "flash" in model:
            flash.append(pct)
        else:
            pro.append(pct)
    pro_pct = max(pro) if pro else None
    flash_pct = max(flash) if flash else None
    resets_in = min(resets) if resets else None
    return pro_pct, flash_pct, resets_in


def fetch_quota(force=False, account=None):
    """`account` is an extra login from accounts.py (None = the default one):
    its own Gemini home, its own cache, its own disk snapshot."""
    now = time.time()
    cache = _cache_for(account)
    disk_name = account.cache_name if account else DISK
    if cache_util.fresh(cache, now, CACHE_TTL_S, FAIL_TTL_S, force):
        return cache["data"]

    auth = _auth_type(account)
    if auth in ("api-key", "vertex-ai"):
        return cache_util.keep_stale(
            cache, now,
            f"Gemini auth type {auth} not supported (need OAuth)",
            _EMPTY, disk_name=disk_name)

    blob = _read_creds(account)
    if not blob or not blob.get("access_token"):
        return cache_util.keep_stale(
            cache, now, "not signed in to Gemini CLI", _EMPTY,
            disk_name=disk_name)

    try:
        plan, blob = _tier_label(blob, account)
        token, blob = _access_token(blob, account)
        if not token:
            raise RuntimeError("Gemini access_token missing")
        quota = _post_json(QUOTA_URL, token, {})
        pro_pct, flash_pct, resets_in = _buckets(quota)
        ok = pro_pct is not None or flash_pct is not None
        out = {
            "ok": ok,
            "plan": plan,
            "error": None if ok else "no Gemini quota buckets",
            "pro": quota_util.pool(pro_pct, resets_in, DAY_WINDOW_S),
            "flash": quota_util.pool(flash_pct, resets_in, DAY_WINDOW_S),
            "stale": False,
        }
        if out["ok"]:
            return cache_util.store(cache, now, out, disk_name=disk_name)
        return cache_util.keep_stale(
            cache, now, out["error"], _EMPTY, disk_name=disk_name)
    except urllib.error.HTTPError as exc:
        body = ""
        try:
            body = exc.read().decode("utf-8", errors="replace")
        except Exception:  # noqa: BLE001
            pass
        if "UNSUPPORTED_CLIENT" in body or "IneligibleTier" in body:
            err = "Gemini consumer OAuth deprecated — try Antigravity later"
        else:
            err = f"Gemini HTTP {exc.code}"
        return cache_util.keep_stale(
            cache, now, err, _EMPTY, disk_name=disk_name)
    except Exception as exc:  # noqa: BLE001
        return cache_util.keep_stale(
            cache, now, str(exc), _EMPTY, disk_name=disk_name)
