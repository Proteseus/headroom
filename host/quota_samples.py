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
value is stable across samples by construction, so it is carried on each row.
In practice the sources report `resets_in_s` loosely enough that it is not
stable at all, so a derived start only replaces the previous one once a full
window has passed — see `window_start_for`. Reads then select by sample *time*
inside that window, so labels forked before the hold still reunite on the chart.

Stdlib only.
"""

from __future__ import annotations

import json
import os
import threading
import time

import sources_config

STORE_PATH = os.path.expanduser("~/.headroom/quota_samples.jsonl")

# One row per pool per bucket. Fine enough to regress a 5h session window,
# coarse enough that a week of samples stays small.
BUCKET_S = 5 * 60
RETENTION_S = 14 * 24 * 3600
# Rewrite the file once it grows past this many lines (~2x a full retention
# window), dropping rows older than the cutoff.
COMPACT_AT_LINES = 60_000
# Slack on "a full window later", so a reset observed slightly early still
# reads as a roll rather than jitter.
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


# Derived from sources_config.QUOTA_SOURCES — add pools there, not here.
POOLS = tuple(
    Pool(provider, pool, key, default_window_s)
    for provider, pool, key, default_window_s in sources_config.pool_rows()
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
    """Derive the window's start, holding `previous` until the window rolls.

    A window that genuinely rolled starts a full window after the last one, so
    that is the bar a new estimate has to clear. Anything short of it is the
    source misreporting `resets_in_s` — most often a cached response served
    after the machine wakes, which freezes `resets_in_s` while `now` keeps
    moving and walks the derived start forward a poll interval at a time.

    Holding rather than snapping matters because a fork is not cosmetic: every
    sample collected before it belongs to a window nothing queries again, which
    is enough to starve the burndown fit of the history it needs.
    """
    window_s = int(window_s)
    elapsed = window_s - max(0, min(int(resets_in_s), window_s))
    start = int(round(now - elapsed))
    if previous is None:
        return start
    rolled = start >= int(previous) + window_s - WINDOW_TOLERANCE_S
    return start if rolled else int(previous)


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


def latest_window_start(provider, pool):
    """window_start on the newest sample for one pool, or None."""
    rows = read(provider=provider, pool=pool)
    for row in reversed(rows):
        start = row.get("window_start")
        if isinstance(start, (int, float)):
            return int(start)
    return None


def current_window(provider, pool, *, window_start=None, window_s=None):
    """Rows belonging to one billing window, oldest first.

    Pass `window_start` (and ideally `window_s`) to pin the live window.
    Selection is by sample *time* falling inside `[start, start+window_s)`, not
    by exact `window_start` equality: `resets_in_s` jitter used to fork a fresh
    label every few polls, and equality then stranded the real burn curve on
    orphan labels the chart never reads again.

    When unpinned, the newest sample's `window_start` / `window_s` define the
    range. A stored label further ahead than the live one no longer wins.
    """
    rows = read(provider=provider, pool=pool)
    if not rows:
        return []
    if window_start is None or window_s is None:
        for row in reversed(rows):
            if window_start is None and isinstance(
                    row.get("window_start"), (int, float)):
                window_start = int(row["window_start"])
            if window_s is None and isinstance(row.get("window_s"), (int, float)):
                window_s = int(row["window_s"])
            if window_start is not None and window_s is not None:
                break
        if window_start is None:
            return rows
    start = int(window_start)
    if not window_s:
        return [row for row in rows if row.get("window_start") == start]
    end = start + int(window_s)
    return [
        row for row in rows
        if isinstance(row.get("t"), (int, float))
        and start <= int(row["t"]) <= end
    ]


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
