"""Shared-secret auth for non-loopback Headroom clients.

`GET /usage` carries repo names, commit subjects, branch names, local server
paths/ports/PIDs, plan tier and USD spend. The host binds 0.0.0.0 so the desk
gadget can reach it, which also puts that document in front of everyone else on
the network — hotel and cafe Wi-Fi included. So anything arriving off-box has
to present a token.

Loopback is exempt: the Mac app, `curl localhost`, and the USB CDC bridge all
already imply access to the machine, and requiring a token there would mean
storing it twice for no gain.

Host token resolution, first hit wins:
  1. `auth_token` in ~/.headroom/config.json
  2. ~/.headroom/token  (generated on first run, mode 0600)

The iOS app uses a separate **mobile token** at ~/.headroom/mobile-token so
its Mac-configured permission scopes cannot be bypassed with the host token
(ESP32 / generic LAN).

Set `"require_auth": false` in config.json to restore the old open-LAN
behaviour. Stdlib only.
"""

from __future__ import annotations

import hmac
import os
import secrets
import threading

import app_config

TOKEN_PATH = os.path.expanduser("~/.headroom/token")
MOBILE_TOKEN_PATH = os.path.expanduser("~/.headroom/mobile-token")
HEADER = "X-Headroom-Token"

_lock = threading.Lock()
_cached_token = None
_cached_mobile_token = None


def _read_token_file(path=None):
    path = path or TOKEN_PATH
    try:
        with open(path) as handle:
            value = handle.read().strip()
    except OSError:
        return None
    return value or None


def _write_token_file(value, path=None):
    """Create the token file readable only by this user."""
    path = path or TOKEN_PATH
    folder = os.path.dirname(path)
    os.makedirs(folder, exist_ok=True)
    tmp = path + ".tmp"
    # os.open with 0o600 so the secret is never briefly world-readable.
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w") as handle:
            handle.write(value + "\n")
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def token():
    """Return the shared secret, generating and persisting one if needed."""
    global _cached_token
    with _lock:
        if _cached_token:
            return _cached_token

        configured = app_config.get("auth_token")
        if isinstance(configured, str) and configured.strip():
            _cached_token = configured.strip()
            return _cached_token

        existing = _read_token_file()
        if existing:
            _cached_token = existing
            return _cached_token

        generated = secrets.token_urlsafe(32)
        try:
            _write_token_file(generated)
        except OSError:
            # Can't persist (read-only home?) — still use it for this run so
            # the LAN stays closed rather than silently falling open.
            pass
        _cached_token = generated
        return _cached_token


def mobile_token():
    """Return the dedicated iOS secret, generating it if needed."""
    global _cached_mobile_token
    with _lock:
        if _cached_mobile_token:
            return _cached_mobile_token

        existing = _read_token_file(MOBILE_TOKEN_PATH)
        if existing:
            _cached_mobile_token = existing
            return _cached_mobile_token

        generated = secrets.token_urlsafe(32)
        try:
            _write_token_file(generated, MOBILE_TOKEN_PATH)
        except OSError:
            pass
        _cached_mobile_token = generated
        return _cached_mobile_token


def required():
    value = app_config.get("require_auth", True)
    if isinstance(value, bool):
        return value
    return True


def presented(headers):
    """Pull a token out of Authorization: Bearer or the X-Headroom-Token header."""
    if headers is None:
        return None
    raw = headers.get(HEADER)
    if raw and raw.strip():
        return raw.strip()
    authorization = headers.get("Authorization") or ""
    parts = authorization.split(None, 1)
    if len(parts) == 2 and parts[0].lower() == "bearer" and parts[1].strip():
        return parts[1].strip()
    return None


def authorized(headers):
    """True when the caller may be served. Never raises."""
    if not required():
        return True
    supplied = presented(headers)
    if not supplied:
        return False
    try:
        return hmac.compare_digest(supplied, token())
    except (TypeError, ValueError):
        return False


def authorized_mobile(headers):
    """True only for the dedicated iOS credential."""
    if not required():
        return True
    supplied = presented(headers)
    if not supplied:
        return False
    try:
        return hmac.compare_digest(supplied, mobile_token())
    except (TypeError, ValueError):
        return False


def reset_for_tests():
    """Drop cached credentials (unit tests only)."""
    global _cached_token, _cached_mobile_token
    with _lock:
        _cached_token = None
        _cached_mobile_token = None
