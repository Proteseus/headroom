"""Claude status.claude.com (Statuspage) for Headroom Attention.

Public page — no credentials. Polls summary.json and sets `alerting` when the
page indicator or an unresolved incident is major/critical. Partial and minor
stay quiet.

Stdlib only. Failures degrade via keep-stale.
"""

from __future__ import annotations

import time
import urllib.error

import cache_util
import http_util

SUMMARY_URL = "https://status.claude.com/api/v2/summary.json"
PAGE_URL = "https://status.claude.com"
CACHE_TTL_S = 60
FAIL_TTL_S = 20
DISK_NAME = "claude-status"
SEVERE = frozenset({"major", "critical"})

_cache = {"t": 0.0, "data": None}
_EMPTY = {
    "ok": False,
    "configured": True,
    "indicator": "none",
    "description": None,
    "alerting": False,
    "incident_name": None,
    "incident_impact": None,
    "url": PAGE_URL,
    "updated_at": None,
    "error": None,
}


def _severe_incidents(incidents):
    """Unresolved incidents whose Statuspage impact is major or critical."""
    out = []
    for incident in incidents or []:
        if not isinstance(incident, dict):
            continue
        if incident.get("resolved_at"):
            continue
        status = (incident.get("status") or "").lower()
        if status == "resolved":
            continue
        impact = (incident.get("impact") or "").lower()
        if impact not in SEVERE:
            continue
        out.append(incident)
    return out


def parse_summary(blob):
    """Map a Statuspage summary.json body to our payload. Pure."""
    status = blob.get("status") if isinstance(blob, dict) else None
    status = status if isinstance(status, dict) else {}
    page = blob.get("page") if isinstance(blob, dict) else None
    page = page if isinstance(page, dict) else {}

    indicator = (status.get("indicator") or "none").lower()
    description = status.get("description") or None
    severe = _severe_incidents(
        blob.get("incidents") if isinstance(blob, dict) else None
    )
    top = severe[0] if severe else None
    alerting = indicator in SEVERE or bool(severe)

    return {
        "ok": True,
        "configured": True,
        "indicator": indicator,
        "description": description,
        "alerting": alerting,
        "incident_name": (top or {}).get("name"),
        "incident_impact": (top or {}).get("impact"),
        "url": page.get("url") or PAGE_URL,
        "updated_at": page.get("updated_at"),
        "error": None,
        "stale": False,
    }


def attention_summary(payload):
    """One-line Attention reason from a fetch payload."""
    name = (payload or {}).get("incident_name")
    if name:
        return name
    description = (payload or {}).get("description")
    if description:
        return f"Claude · {description}"
    return "Claude major outage"


def fetch(force=False):
    """Fetch status.claude.com summary. Never raises."""
    now = time.time()
    if cache_util.fresh(_cache, now, CACHE_TTL_S, FAIL_TTL_S, force):
        return _cache["data"]

    try:
        blob = http_util.request_json(SUMMARY_URL)
        if not isinstance(blob, dict):
            raise ValueError("status page returned non-object JSON")
        return cache_util.store(
            _cache, now, parse_summary(blob), disk_name=DISK_NAME)
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError,
            ValueError, TypeError, OSError) as error:
        return cache_util.keep_stale(
            _cache, now, str(error) or error.__class__.__name__,
            _EMPTY, disk_name=DISK_NAME)
    except Exception as error:
        return cache_util.keep_stale(
            _cache, now, str(error) or error.__class__.__name__,
            _EMPTY, disk_name=DISK_NAME)
