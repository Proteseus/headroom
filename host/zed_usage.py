"""Zed editor plan + edit-prediction quota.

Reads the Zed internet-password Keychain item for https://zed.dev via
SecItemCopyMatching (not `/usr/bin/security`, which puts a shared binary on
the ACL and is the usual SecurityAgent prompt path), then
`GET https://cloud.zed.dev/client/users/me`. CodexBar-equivalent; stdlib only.
"""

from __future__ import annotations

import json
import os
import threading
import time
import urllib.error
import urllib.request

import cache_util
import http_util
import keychain
import quota_util

CACHE_TTL_S = 60
FAIL_TTL_S = 20
DISK = "zed_quota"
ME_URL = "https://cloud.zed.dev/client/users/me"
KEYCHAIN_SERVER = "zed.dev"
UA = "Headroom/1"
MONTH_WINDOW_S = 30 * 86400

_cache = {"t": 0.0, "data": None, "err": None}
_EMPTY = {"ok": False, "plan": None, "predictions": None}

# Sticky Keychain refusals — Deny must not become a 60s SecurityAgent loop.
# Mirrored to disk so a KeepAlive respawn does not immediately re-prompt.
_keychain_denied = False
_deny_lock = threading.Lock()


def _deny_path():
    return os.path.expanduser("~/.headroom/oauth/.denied-zed")


def _is_keychain_denied():
    global _keychain_denied
    with _deny_lock:
        if _keychain_denied:
            return True
    path = _deny_path()
    if os.path.isfile(path):
        with _deny_lock:
            _keychain_denied = True
        return True
    return False


def _mark_keychain_denied(status):
    global _keychain_denied
    with _deny_lock:
        _keychain_denied = True
    try:
        os.makedirs(os.path.dirname(_deny_path()), exist_ok=True)
        with open(_deny_path(), "w") as handle:
            handle.write(f"{status}\n")
    except OSError:
        pass


def rearm_keychain():
    """Clear sticky Keychain refusals so the next fetch may prompt again.

    Bound to a user-initiated refresh — background polls must not clear this.
    """
    global _keychain_denied
    with _deny_lock:
        _keychain_denied = False
    try:
        os.unlink(_deny_path())
    except OSError:
        pass


def _settings_server():
    path = os.path.expanduser("~/.config/zed/settings.json")
    try:
        with open(path) as handle:
            blob = json.load(handle)
    except (OSError, json.JSONDecodeError, TypeError):
        return KEYCHAIN_SERVER
    raw = blob.get("credentials_url") or blob.get("server_url") or ""
    text = str(raw).strip()
    if not text:
        return KEYCHAIN_SERVER
    text = text.replace("https://", "").replace("http://", "").rstrip("/")
    # Only trust Zed's known hosts — never forward Keychain tokens elsewhere.
    if text in ("zed.dev", "staging.zed.dev"):
        return text
    return KEYCHAIN_SERVER


def _keychain_creds(allow_ui=False):
    """Return (user_id, token) from Zed's Keychain item.

    `allow_ui=False` for detection / signed_in — must not pop SecurityAgent.
    A real fetch passes True once so the user can Allow (Touch ID / password);
    Deny sticks until rearm_keychain().
    """
    if _is_keychain_denied():
        return None, None

    server = _settings_server()
    user_id = None
    token = None
    status = keychain.ERR_SEC_ITEM_NOT_FOUND

    try:
        status, token, user_id = keychain.get_internet_password(
            server, allow_ui=allow_ui)
    except keychain.KeychainError:
        status, token, user_id = keychain.ERR_SEC_ITEM_NOT_FOUND, None, None

    if status in (
        keychain.ERR_SEC_USER_CANCELED,
        keychain.ERR_SEC_AUTH_FAILED,
    ):
        _mark_keychain_denied(status)
        return None, None

    if status == keychain.ERR_SEC_SUCCESS and token:
        return user_id, token.strip() or None

    # Older Zed builds used a generic password under https://<server>.
    try:
        status, raw = keychain.get_generic_password(
            f"https://{server}", allow_ui=allow_ui)
    except keychain.KeychainError:
        return None, None
    if status in (
        keychain.ERR_SEC_USER_CANCELED,
        keychain.ERR_SEC_AUTH_FAILED,
    ):
        _mark_keychain_denied(status)
        return None, None
    if status == keychain.ERR_SEC_SUCCESS and raw:
        return None, raw.strip() or None
    return None, None


def signed_in():
    """Cheap presence check — never prompts."""
    _, token = _keychain_creds(allow_ui=False)
    return bool(token)


def _fetch_me(user_id, token):
    auth = f"{user_id} {token}" if user_id else token
    return http_util.request_json(
        ME_URL, auth=auth, user_agent=UA, timeout=12)


def _map(blob):
    plan = blob.get("plan") if isinstance(blob, dict) else None
    if not isinstance(plan, dict):
        plan = {}
    label = plan.get("plan_v3") or plan.get("name") or plan.get("plan")
    if isinstance(label, str):
        label = label.replace("_", " ").strip().title()
    usage = plan.get("usage") if isinstance(plan.get("usage"), dict) else {}
    preds = usage.get("edit_predictions")
    pct = None
    if isinstance(preds, dict):
        if preds.get("unlimited"):
            pct = 0.0
        else:
            pct = quota_util.used_pct(preds.get("used"), preds.get("limit"))
    period = plan.get("subscription_period")
    resets_in = None
    if isinstance(period, dict):
        resets_in = quota_util.resets_from_iso(period.get("ended_at"))
    overdue = bool(plan.get("has_overdue_invoices"))
    ok = pct is not None or label is not None
    return {
        "ok": ok,
        "plan": label,
        "error": "overdue invoice" if overdue and ok else (
            None if ok else "no Zed plan data"),
        "predictions": quota_util.pool(pct, resets_in, MONTH_WINDOW_S),
        "stale": False,
    }


def fetch_quota(force=False):
    now = time.time()
    if cache_util.fresh(_cache, now, CACHE_TTL_S, FAIL_TTL_S, force):
        return _cache["data"]

    # Real fetch may Allow once (Touch ID). Detection stays fail-closed.
    user_id, token = _keychain_creds(allow_ui=True)
    if not token:
        return cache_util.keep_stale(
            _cache, now, "not signed in to Zed", _EMPTY, disk_name=DISK)

    try:
        blob = _fetch_me(user_id, token)
        out = _map(blob)
        if out.get("ok"):
            return cache_util.store(_cache, now, out, disk_name=DISK)
        return cache_util.keep_stale(
            _cache, now, out.get("error") or "Zed quota unavailable",
            _EMPTY, disk_name=DISK)
    except urllib.error.HTTPError as exc:
        return cache_util.keep_stale(
            _cache, now, f"Zed HTTP {exc.code}", _EMPTY, disk_name=DISK)
    except Exception as exc:  # noqa: BLE001
        return cache_util.keep_stale(
            _cache, now, str(exc), _EMPTY, disk_name=DISK)
