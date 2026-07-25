"""Raw quota sample log — the time series behind burndown + forecasting.

`daily_burn` answers "how many points did I burn on Tuesday". That is the wrong
instrument for an intra-window burndown, for three reasons: it is daily
granularity (a weekly window gives 7 stair steps), it is keyed by calendar date
while the plan windows roll from an arbitrary start, and it detects a window
reset only to re-baseline, throwing the boundary away.

So this module keeps the primitive both of those need: (t, pct) samples per
pool, tagged with the window they belong to. Everything downstream — the
burndown chart, time-to-exhaustion, pace deltas, per-window history — is a
query over this file rather than new collection.

Storage is append-only JSONL at ~/.headroom/quota_samples.jsonl, downsampled to
one row per pool per BUCKET_S. At 5-minute buckets that is ~7 rows/interval and
~28k rows over the retention window, a few MB. Appending beats rewriting a JSON
blob every tick, and the file stays greppable.

Window identity is derived, not stored by the API: a pool reporting `window_s`
and `resets_in_s` implies `window_start = now - (window_s - resets_in_s)`. That
value is stable across samples by construction, so it is carried on each row
and used to group samples into windows. Small API jitter is absorbed by
snapping to the previous window_start when it is within WINDOW_TOLERANCE_S.

Stdlib only.
"""

from __future__ import annotations

import json
import os
import threading
import time

import oauth_usage

STORE_PATH = os.path.expanduser("~/.headroom/quota_samples.jsonl")

# One row per pool per bucket. Fine enough to regress a 5h session window,
# coarse enough that a week of samples stays small.
BUCKET_S = 5 * 60
RETENTION_S = 14 * 24 * 3600
# Rewrite the file once it grows past this many lines (~2x a full retention
# window), dropping rows older than the cutoff.
COMPACT_AT_LINES = 60_000
# Two window_start estimates closer than this are the same window.
WINDOW_TOLERANCE_S = 15 * 60
# Bytes read from the tail to reseed bucket/window state after a restart.
TAIL_BYTES = 64 * 1024


class Pool:
    """One quota meter: a provider payload key plus its window length."""

    __slots__ = ("provider", "pool", "key", "default_window_s")

    def __init__(self, provider, pool, key, default_window_s=None):
        self.provider = provider
        self.pool = pool
        self.key = key
        self.default_window_s = default_window_s

    @property
    def id(self):
        return (self.provider, self.pool)


# Claude and Codex both expose Anthropic-style session/weekly buckets. Cursor's
# pools ride the billing cycle, so their length only ever comes from the
# payload.
POOLS = (
    Pool("claude", "session", "session", oauth_usage.SESSION_WINDOW_S),
    Pool("claude", "week", "week", oauth_usage.WEEK_WINDOW_S),
    Pool("codex", "session", "session", oauth_usage.SESSION_WINDOW_S),
    Pool("codex", "week", "week", oauth_usage.WEEK_WINDOW_S),
    Pool("cursor", "total", "total"),
    Pool("cursor", "auto", "auto"),
    Pool("cursor", "api", "api"),
)

BY_ID = {pool.id: pool for pool in POOLS}
PROVIDERS = tuple(dict.fromkeys(pool.provider for pool in POOLS))

_lock = threading.Lock()
# (provider, pool) -> last bucket epoch written, so a restart or a fast poll
# does not duplicate a row.
_last_bucket = {}
# (provider, pool) -> last window_start, for jitter snapping.
_last_window = {}
_seeded = False


def _num(value):
    if isinstance(value, bool) or value is None:
        return None
    try:
        out = float(value)
    except (TypeError, ValueError):
        return None
    return out if out == out else None  # drop NaN


def extract(provider, pool_id, payload):
    """Pull {pct, window_s, resets_in_s} for one pool out of a source payload.

    Returns None when the payload has nothing usable, which is the normal case
    for a provider the user has not configured.
    """
    spec = BY_ID.get((provider, pool_id))
    if spec is None or not isinstance(payload, dict):
        return None

    bucket = payload.get(spec.key)
    if not isinstance(bucket, dict):
        return None

    pct = _num(bucket.get("pct"))
    if pct is None:
        return None

    window_s = _num(bucket.get("window_s")) or spec.default_window_s
    # Cursor reports one billing cycle at the top level for every pool.
    resets_in_s = _num(bucket.get("resets_in_s"))
    if resets_in_s is None:
        resets_in_s = _num(payload.get("resets_in_s"))

    if not window_s or window_s <= 0 or resets_in_s is None:
        return None

    return {
        "pct": round(pct, 2),
        "window_s": int(window_s),
        "resets_in_s": max(0, int(resets_in_s)),
    }


def window_start_for(now, window_s, resets_in_s, previous=None):
    """Derive the window's start, snapping to `previous` when within jitter."""
    elapsed = window_s - max(0, min(int(resets_in_s), int(window_s)))
    start = int(round(now - elapsed))
    if previous is not None and abs(start - previous) <= WINDOW_TOLERANCE_S:
        return int(previous)
    return start


def _iter_rows(handle):
    for line in handle:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except (json.JSONDecodeError, UnicodeDecodeError):
            continue
        if isinstance(row, dict) and row.get("t") is not None:
            yield row


def _seed_locked():
    """Reseed bucket/window state from the file tail so a restart is a no-op."""
    global _seeded
    if _seeded:
        return
    _seeded = True
    try:
        size = os.path.getsize(STORE_PATH)
        with open(STORE_PATH, "rb") as handle:
            if size > TAIL_BYTES:
                handle.seek(size - TAIL_BYTES)
                handle.readline()  # discard the partial first line
            raw = handle.read().decode("utf-8", errors="replace")
    except OSError:
        return

    for row in _iter_rows(raw.splitlines()):
        key = (row.get("provider"), row.get("pool"))
        if key not in BY_ID:
            continue
        bucket = row.get("t")
        if isinstance(bucket, (int, float)):
            prev = _last_bucket.get(key)
            if prev is None or bucket > prev:
                _last_bucket[key] = int(bucket)
        start = row.get("window_start")
        if isinstance(start, (int, float)):
            _last_window[key] = int(start)


def _append_locked(rows):
    if not rows:
        return
    folder = os.path.dirname(STORE_PATH)
    if folder:
        os.makedirs(folder, exist_ok=True)
    with open(STORE_PATH, "a") as handle:
        for row in rows:
            handle.write(json.dumps(row, separators=(",", ":")) + "\n")


def record(state, *, now=None, persist=True):
    """Sample every pool present in `state` ({source_id: payload}).

    Returns the rows written (empty when every pool is still inside its current
    bucket). Never raises — a sampling failure must not take down a poll tick.
    """
    now = time.time() if now is None else float(now)
    bucket_t = int(now // BUCKET_S) * BUCKET_S
    written = []

    try:
        with _lock:
            _seed_locked()
            for spec in POOLS:
                payload = (state or {}).get(spec.provider)
                if not isinstance(payload, dict) or not payload.get("ok"):
                    continue
                reading = extract(spec.provider, spec.pool, payload)
                if reading is None:
                    continue
                if _last_bucket.get(spec.id) == bucket_t:
                    continue  # already sampled this bucket

                start = window_start_for(
                    now,
                    reading["window_s"],
                    reading["resets_in_s"],
                    previous=_last_window.get(spec.id),
                )
                _last_bucket[spec.id] = bucket_t
                _last_window[spec.id] = start
                written.append({
                    "t": bucket_t,
                    "provider": spec.provider,
                    "pool": spec.pool,
                    "pct": reading["pct"],
                    "window_s": reading["window_s"],
                    "resets_in_s": reading["resets_in_s"],
                    "window_start": start,
                })

            if persist and written:
                _append_locked(written)
    except OSError as exc:
        print("quota_samples write error:", exc)
        return []

    if persist and written:
        _maybe_compact(now)
    return written


def read(*, provider=None, pool=None, since=None, window_start=None):
    """Return matching rows, oldest first. Missing file reads as empty."""
    out = []
    try:
        with open(STORE_PATH) as handle:
            for row in _iter_rows(handle):
                if provider is not None and row.get("provider") != provider:
                    continue
                if pool is not None and row.get("pool") != pool:
                    continue
                if since is not None and row.get("t", 0) < since:
                    continue
                if (window_start is not None
                        and row.get("window_start") != window_start):
                    continue
                out.append(row)
    except OSError:
        return []
    out.sort(key=lambda row: row.get("t") or 0)
    return out


def current_window(provider, pool, *, window_start=None):
    """Rows belonging to the newest window for one pool, oldest first.

    Pass `window_start` to pin a specific window; otherwise the newest
    window_start present in the file wins.
    """
    rows = read(provider=provider, pool=pool)
    if not rows:
        return []
    if window_start is None:
        starts = [
            row["window_start"] for row in rows
            if isinstance(row.get("window_start"), (int, float))
        ]
        if not starts:
            return rows
        window_start = max(starts)
    return [row for row in rows if row.get("window_start") == window_start]


def windows(provider, pool):
    """Distinct window_start values for one pool, oldest first."""
    starts = {
        row["window_start"] for row in read(provider=provider, pool=pool)
        if isinstance(row.get("window_start"), (int, float))
    }
    return sorted(starts)


def _line_count():
    try:
        with open(STORE_PATH, "rb") as handle:
            return sum(1 for _ in handle)
    except OSError:
        return 0


def _maybe_compact(now):
    if _line_count() <= COMPACT_AT_LINES:
        return
    compact(now=now)


def compact(*, now=None):
    """Drop rows older than the retention cutoff. Returns rows kept."""
    now = time.time() if now is None else float(now)
    cutoff = now - RETENTION_S
    try:
        with open(STORE_PATH) as handle:
            kept = [row for row in _iter_rows(handle) if row.get("t", 0) >= cutoff]
    except OSError:
        return 0

    tmp = STORE_PATH + ".tmp"
    try:
        with open(tmp, "w") as handle:
            for row in kept:
                handle.write(json.dumps(row, separators=(",", ":")) + "\n")
        os.replace(tmp, STORE_PATH)
    except OSError as exc:
        print("quota_samples compact error:", exc)
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return 0
    return len(kept)


def reset_for_tests():
    """Clear in-memory bucket/window state (unit tests only)."""
    global _seeded
    with _lock:
        _last_bucket.clear()
        _last_window.clear()
        _seeded = False
