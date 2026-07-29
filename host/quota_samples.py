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

Window identity is derived, not stored by the API. The anchor is the *reset
instant* — `window_end = now + resets_in_s` — rather than the start, because
the end is the one moment the source actually reports and the one the UI
prints. Deriving the start from a held end (`end - window_s`) is what keeps a
chart's axis and its "6d 23h to reset" caption from disagreeing; anchoring the
other way round lets them drift apart by days.

In practice the sources report `resets_in_s` loosely enough that a fresh
reading is not stable at all, so a derived end only replaces the held one once
a full window has passed — see `window_for`. The exception is a reset granted
out of band (Codex handing everyone a fresh week mid-window), which no
elapsed-time rule can ever recognise; `rolled_window` detects those from the
reading itself, and `rolls` reads them back out of the stored labels so the
chart can mark the moment instead of silently starting a new line. Reads then
select by sample *time* inside the window, so labels forked before the hold
still reunite on the chart.

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
# Out-of-band reset detection. Both bars have to be cleared at once — see
# `rolled_window` for why either alone is ambiguous.
RESET_MIN_DROP_PCT = 1.0
RESET_MIN_GAIN_S = 15 * 60
# How far back `rolls` looks, and how many it hands to a caller. The span
# covers the overview chart's week so a grant stays marked for as long as the
# history it interrupts is still on screen.
ROLL_LOOKBACK_S = 7 * 24 * 3600
MAX_ROLLS = 8
# How far ahead of its held reset a window has to roll before `rolls` calls it
# a grant, as a fraction of the window. Flat minutes are the wrong bar: a 5h
# session that rolls 18 minutes early is the source rounding, while a weekly
# window doing the same thing is still just the week ending. The real grants
# clear their old reset by days.
ROLL_GRANT_MIN_EARLY = 0.1
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
# (provider, pool) -> newest row written. Carries the bucket (so a restart or a
# fast poll does not duplicate a row) and the pct/resets_in/window_end a roll
# decision needs.
_last_row = {}
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


def _previous_end(previous, window_s):
    """The reset instant carried by a stored row, or None."""
    if not isinstance(previous, dict):
        return None
    end = _num(previous.get("window_end"))
    if end is not None:
        return int(end)
    start = _num(previous.get("window_start"))
    # Rows written before window_end was carried on each sample.
    return None if start is None else int(start) + int(window_s)


def rolled_window(previous, pct, resets_in_s, now):
    """True when this reading belongs to a later window than `previous`'s.

    Two independent facts have to agree, because either one alone is
    ambiguous. Used percent fell, which cannot happen inside a window — you
    do not un-spend — except that a credit grant lowers it without rolling
    anything. And `resets_in_s` jumped past the decay the clock predicts,
    which jitter and post-wake cached responses also do — except that those
    repeat the previous `pct` rather than dropping it. Only a real roll
    produces both at the same moment.

    Over two weeks of live samples across every pool this fires exactly on the
    genuine rolls and on nothing else, including the multi-hour `resets_in_s`
    jumps that follow a sleep.
    """
    prev_pct = _num((previous or {}).get("pct"))
    prev_resets = _num((previous or {}).get("resets_in_s"))
    prev_t = _num((previous or {}).get("t"))
    if prev_pct is None or prev_resets is None or prev_t is None:
        return False
    if prev_pct - pct < RESET_MIN_DROP_PCT:
        return False
    expected = prev_resets - max(0.0, now - prev_t)
    return resets_in_s - expected >= RESET_MIN_GAIN_S


def rolls(rows, *, since=None, limit=MAX_ROLLS):
    """Granted resets visible in `rows` (one pool's samples, oldest first).

    Every window boundary shows up in the log as a change of `window_start`.
    Most are the window simply running out, which is not news: the axis already
    ends there and the chart draws the rule. The ones worth surfacing are the
    grants — Codex handing back a week you had already spent — and those are
    exactly the boundaries that landed while the previous window's reset was
    still in the future.

    Read off the stored labels rather than by re-running `rolled_window`, so
    what the chart marks and what the log says can never disagree: a relabelled
    row moves both at once.

    Returns [{t, kind, forgiven_pct}, …], oldest first.
    """
    out = []
    previous = None
    for row in rows:
        start = row.get("window_start")
        if (previous is not None
                and start is not None
                and start != previous.get("window_start")):
            window_s = _num(previous.get("window_s")) or _num(row.get("window_s"))
            previous_end = _previous_end(previous, window_s or 0)
            t = _num(row.get("t"))
            forgiven = ((_num(previous.get("pct")) or 0.0)
                        - (_num(row.get("pct")) or 0.0))
            early_by = max(WINDOW_TOLERANCE_S,
                           (window_s or 0) * ROLL_GRANT_MIN_EARLY)
            if (previous_end is not None
                    and t is not None
                    and previous_end - t > early_by
                    and forgiven >= RESET_MIN_DROP_PCT):
                out.append({
                    "t": int(t),
                    "kind": "granted",
                    "forgiven_pct": round(forgiven, 2),
                })
        previous = row
    if since is not None:
        out = [roll for roll in out if roll["t"] >= since]
    return out[-limit:] if limit else out


def window_for(now, window_s, resets_in_s, *, pct=None, previous=None):
    """Derive `(start, end)` for one reading, holding the end against jitter.

    A window that rolled on time puts its reset a full window after the held
    one, so that is the bar a fresh reading has to clear. Anything short of it
    is the source misreporting `resets_in_s` — most often a cached response
    served after the machine wakes, which freezes `resets_in_s` while `now`
    keeps moving and walks the derived window forward a poll at a time.

    Holding rather than snapping matters because a fork is not cosmetic: every
    sample collected before it belongs to a window nothing queries again, which
    is enough to starve the burndown fit of the history it needs. But holding
    against *everything* is how a reset granted early stays invisible for days,
    so `rolled_window` gets a say too.
    """
    window_s = int(window_s)
    resets_in_s = max(0, min(int(resets_in_s), window_s))
    end = int(round(now + resets_in_s))
    previous_end = _previous_end(previous, window_s)
    if previous_end is not None:
        on_time = end >= previous_end + window_s - WINDOW_TOLERANCE_S
        early = pct is not None and rolled_window(
            previous, pct, resets_in_s, now)
        if not (on_time or early):
            end = previous_end
    return end - window_s, end


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


def _relabel_locked(rows):
    """Replay `window_for` over every row, oldest first. Returns rows changed.

    Window labels are derived, so they are only ever as good as the rule that
    derived them. Replaying that rule across the whole log is what lets a fix
    reach the history it was already wrong about; without it a window
    mislabelled before the fix stays mislabelled until it rolls on its own,
    which on a weekly pool is a week of wrong charts.

    Only the derived keys move. The readings themselves are never touched.
    """
    rows.sort(key=lambda row: row.get("t") or 0)
    previous = {}
    changed = 0
    for row in rows:
        key = (row.get("provider"), row.get("pool"))
        spec = BY_ID.get(key)
        if spec is None:
            continue
        window_s = _num(row.get("window_s")) or spec.default_window_s
        pct = _num(row.get("pct"))
        resets_in_s = _num(row.get("resets_in_s"))
        if not window_s or pct is None or resets_in_s is None:
            continue
        start, end = window_for(row["t"], int(window_s), int(resets_in_s),
                                pct=pct, previous=previous.get(key))
        if (row.get("window_start") != start
                or row.get("window_end") != end):
            changed += 1
        row["window_start"] = start
        row["window_end"] = end
        previous[key] = row
    return changed


def _migrate_locked():
    """One-shot relabel of a store written before windows carried their end."""
    try:
        with open(STORE_PATH) as handle:
            rows = list(_iter_rows(handle))
    except OSError:
        return False
    stale = any(row.get("window_end") is None
                and (row.get("provider"), row.get("pool")) in BY_ID
                for row in rows)
    if not stale:
        return False
    if _relabel_locked(rows):
        print(f"quota_samples: relabelled {len(rows)} rows onto held windows")
    return _rewrite(rows)


def _seed_locked():
    """Reseed per-pool state from the file tail so a restart is a no-op."""
    global _seeded
    if _seeded:
        return
    _seeded = True
    _migrate_locked()
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
        bucket = _num(row.get("t"))
        if bucket is None:
            continue
        previous = _last_row.get(key)
        if previous is None or bucket > _num(previous.get("t")):
            _last_row[key] = row


def _rewrite(rows):
    """Replace the store with `rows`, atomically. False when it could not.

    Called both under `_lock` (relabelling) and outside it (compaction), which
    is why it takes rows rather than reaching for module state.
    """
    tmp = STORE_PATH + ".tmp"
    try:
        with open(tmp, "w") as handle:
            for row in rows:
                handle.write(json.dumps(row, separators=(",", ":")) + "\n")
        os.replace(tmp, STORE_PATH)
    except OSError as exc:
        print("quota_samples rewrite error:", exc)
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return False
    return True


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
                previous = _last_row.get(spec.id)
                if previous is not None and _num(previous.get("t")) == bucket_t:
                    continue  # already sampled this bucket

                start, end = window_for(
                    now,
                    reading["window_s"],
                    reading["resets_in_s"],
                    pct=reading["pct"],
                    previous=previous,
                )
                row = {
                    "t": bucket_t,
                    "provider": spec.provider,
                    "pool": spec.pool,
                    "pct": reading["pct"],
                    "window_s": reading["window_s"],
                    "resets_in_s": reading["resets_in_s"],
                    "window_start": start,
                    "window_end": end,
                }
                _last_row[spec.id] = row
                written.append(row)

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


def latest_row(provider, pool):
    """The newest stored sample for one pool, or None.

    Callers pass this straight back into `window_for` as `previous`: it is the
    only thing a roll decision needs, and reading it here keeps that decision
    in one place rather than one copy per caller.
    """
    rows = read(provider=provider, pool=pool)
    return rows[-1] if rows else None


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
    return len(kept) if _rewrite(kept) else 0


def reset_for_tests():
    """Clear in-memory per-pool state (unit tests only)."""
    global _seeded
    with _lock:
        _last_row.clear()
        _seeded = False
