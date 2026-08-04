"""Canonical Codex global-reset announcements from codex-resets.com.

OpenAI's Codex lead announces mid-window grants on X; that site watches the
feed and publishes every verified announcement as JSON. Headroom already
detects grants in the local sample log — those are what your curve actually
did. This module is the public record of when a reset was *announced*, so the
heatmap can reach past the sample window and stay aligned with the same
timeline everyone else is looking at.

Public page — no credentials. Stdlib only. Failures keep the last good body.
"""

from __future__ import annotations

import time
import urllib.error
from datetime import datetime, timezone

import cache_util
import http_util

API_URL = "https://codex-resets.com/api/resets"
PAGE_URL = "https://codex-resets.com"
CACHE_TTL_S = 60 * 60          # announcements land a few times a week
FAIL_TTL_S = 15 * 60
DISK_NAME = "codex-resets"
# How close a local sample-detected grant has to land to an announcement to
# count as the same event. Propagation is usually minutes; banked-credit
# spends that are hours away stay local-only.
MATCH_WINDOW_S = 6 * 3600

_cache = {"t": 0.0, "data": None}
_EMPTY = {
    "ok": False,
    "events": [],
    "stats": None,
    "url": PAGE_URL,
    "generated_at": None,
    "error": None,
    "stale": False,
}


def _parse_announced_at(value):
    """ISO-8601 → epoch seconds, or None."""
    if not isinstance(value, str) or not value:
        return None
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        return int(datetime.fromisoformat(text).timestamp())
    except ValueError:
        return None


def parse_feed(blob):
    """Map `/api/resets` JSON to our payload. Pure."""
    raw = blob.get("events") if isinstance(blob, dict) else None
    events = []
    for row in raw or []:
        if not isinstance(row, dict):
            continue
        announced_at = _parse_announced_at(row.get("announced_at"))
        if announced_at is None:
            continue
        tweet_id = row.get("tweet_id")
        tweet_url = row.get("tweet_url")
        if not tweet_url and tweet_id:
            tweet_url = f"https://x.com/thsottiaux/status/{tweet_id}"
        events.append({
            "t": announced_at,
            "kind": "granted",
            "source": "announced",
            "forgiven_pct": None,
            "tweet_id": str(tweet_id) if tweet_id is not None else None,
            "tweet_url": tweet_url,
            "text": row.get("text"),
            "announced_at": row.get("announced_at"),
        })
    events.sort(key=lambda event: event["t"])
    return {
        "ok": True,
        "events": events,
        "stats": blob.get("stats") if isinstance(blob, dict) else None,
        "url": PAGE_URL,
        "generated_at": (
            blob.get("generated_at") if isinstance(blob, dict) else None
        ),
        "error": None,
        "stale": False,
    }


def match(observed, announced):
    """Pair local detections with announcements within MATCH_WINDOW_S.

    Returns (merged_observed, unmatched_announced). Each observed event keeps
    its sample instant (`t`) so the burndown rule still lands on the curve
    jump; a match copies tweet metadata on and sets `source` to `both`.
    Unmatched announcements are the history the sample log never saw.
    """
    remaining = list(announced or [])
    merged = []
    for obs in observed or []:
        t = obs.get("t")
        if t is None:
            continue
        best_i = None
        best_delta = None
        for i, ann in enumerate(remaining):
            delta = abs(int(ann["t"]) - int(t))
            if delta > MATCH_WINDOW_S:
                continue
            if best_delta is None or delta < best_delta:
                best_delta = delta
                best_i = i
        row = {
            "t": int(t),
            "kind": obs.get("kind") or "granted",
            "forgiven_pct": obs.get("forgiven_pct"),
            "source": "observed",
            "tweet_id": None,
            "tweet_url": None,
        }
        if best_i is not None:
            ann = remaining.pop(best_i)
            row["source"] = "both"
            row["tweet_id"] = ann.get("tweet_id")
            row["tweet_url"] = ann.get("tweet_url")
            # Prefer the announcement instant only when we have no sample time
            # — we always do here, so the curve mark stays put.
        merged.append(row)
    return merged, remaining


def events(*, force=False):
    """Announcement list, oldest first. Never raises; empty on total miss."""
    payload = fetch(force=force)
    return list(payload.get("events") or [])


def fetch(force=False):
    """Fetch the public reset feed. Never raises."""
    now = time.time()
    if cache_util.fresh(_cache, now, CACHE_TTL_S, FAIL_TTL_S, force):
        return _cache["data"]

    try:
        blob = http_util.request_json(API_URL)
        if not isinstance(blob, dict):
            raise ValueError("codex-resets returned non-object JSON")
        return cache_util.store(
            _cache, now, parse_feed(blob), disk_name=DISK_NAME)
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError,
            ValueError, TypeError, OSError) as error:
        return cache_util.keep_stale(
            _cache, now, str(error) or error.__class__.__name__,
            _EMPTY, disk_name=DISK_NAME)
    except Exception as error:
        return cache_util.keep_stale(
            _cache, now, str(error) or error.__class__.__name__,
            _EMPTY, disk_name=DISK_NAME)


def reset_for_tests():
    """Clear the in-memory cache (unit tests only)."""
    _cache["t"] = 0.0
    _cache["data"] = None
