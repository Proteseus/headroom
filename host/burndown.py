"""Burndown + time-to-exhaustion forecast for one quota pool.

The gauge every other tool shows ("62%") answers a question nobody actually
asks continuously. The useful question is whether the budget survives the
window, which needs three things: where an even spend would put you (free —
that is `pace_pct`), where you actually are (free — the current reading), and
the shape of how you got here (not free — that is `quota_samples`).

Everything here is expressed in *remaining* percent so the chart reads as a
burndown: 100 at the window start, 0 at exhaustion, and a straight ideal line
between the window's start and its reset. Actual below ideal means burning
faster than even pace.

The forecast is a least-squares fit over the trailing slice of the current
window, extended to the x-axis. Deliberately linear: with a few hundred samples
per window, anything fancier fits noise, and a wrong confident forecast is
worse than an honest rough one. When the fit has too little to work with, every
forecast field comes back None and the caller shows history only.

Series are emitted as [[t, remaining_pct], ...] pairs rather than objects. At
48 points per pool that is the difference between ~600 bytes and ~1.5KB, which
matters because this rides the same document the ESP32 pulls over USB CDC.

One source of truth: the firmware and the menu bar draw these numbers, they
never compute them. Stdlib only.
"""

from __future__ import annotations

import time
from datetime import datetime

import cache_util
import oauth_usage
import quota_samples

# Points per emitted series. Enough to see the shape on a 368px panel.
DEFAULT_POINTS = 48
# A fit needs at least this many samples spanning at least this much time
# before it is allowed to claim a forecast.
MIN_FIT_SAMPLES = 3
MIN_FIT_SPAN_S = 20 * 60
# Trailing slice used for the fit. Floor keeps a 5h session from fitting on
# minutes of noise; ceiling lets a month-long Cursor cycle see more than a
# day of history (Cursor's meter often jumps, then sits flat for >24h).
FIT_LOOKBACK_MIN_S = 3600
FIT_LOOKBACK_MAX_S = 7 * 24 * 3600
# Remaining-percent gap that counts as meaningfully off even pace.
DEFICIT_PCT = 5.0

STATUS_OK = "ok"
STATUS_AHEAD = "ahead"
STATUS_CRITICAL = "critical"
# Already spent. Distinct from `critical` because there is nothing left to act
# on: the UI desaturates it rather than raising an alarm.
STATUS_EXHAUSTED = "exhausted"


def _round(value, digits=1):
    return None if value is None else round(value, digits)


def _rate_unit(window_s):
    """Points-per-hour reads sensibly for a 5h window; per-day does not."""
    return "hour" if window_s <= 24 * 3600 else "day"


def _rate_seconds(unit):
    return 3600.0 if unit == "hour" else 86400.0


def _fmt_rate(value):
    """Rates span three orders of magnitude across pools; keep them legible."""
    if value is None:
        return None
    if value >= 10:
        return f"{value:.0f}"
    if value >= 1:
        return f"{value:.1f}"
    # Sub-1 rates need two places to say anything, but "0.20" reads worse
    # than "0.2" in a sentence.
    return f"{value:.2f}".rstrip("0").rstrip(".")


def _points(value):
    count = f"{abs(value):.0f}"
    return f"{count} point" if count == "1" else f"{count} points"


def _slope_per_s(points):
    """Least-squares slope (remaining pct per second). None when degenerate."""
    n = len(points)
    if n < 2:
        return None
    mean_t = sum(p[0] for p in points) / n
    mean_r = sum(p[1] for p in points) / n
    numerator = sum((t - mean_t) * (r - mean_r) for t, r in points)
    denominator = sum((t - mean_t) ** 2 for t, _ in points)
    if denominator <= 0:
        return None
    return numerator / denominator


def _downsample(points, limit, start, end):
    """Thin `points` to at most `limit`, evenly by time, keeping both ends.

    The ends are pinned because they carry meaning the middle does not: the
    newest point is the current reading, and the oldest is where the window
    opened. Letting slot rounding swallow either one leaves a curve that starts
    or stops short of the axis it is drawn against.
    """
    if len(points) <= limit:
        return list(points)
    span = max(1.0, float(end - start))
    slots = {}
    for t, r in points:
        idx = int(min(limit - 1, max(0, (t - start) / span * (limit - 1))))
        slots[idx] = (t, r)  # last write per slot wins
    out = sorted(slots.values(), key=lambda p: p[0])
    oldest = min(points, key=lambda p: p[0])
    if out and out[0][0] != oldest[0]:
        out.insert(0, oldest)
    newest = max(points, key=lambda p: p[0])
    if out and out[-1][0] != newest[0]:
        out.append(newest)
    return out


def _when(timestamp, tz, now):
    """Short human time for a forecast instant, in the user's timezone."""
    if timestamp is None:
        return None
    try:
        moment = datetime.fromtimestamp(timestamp, tz)
        today = datetime.fromtimestamp(now, tz).date()
    except (OverflowError, OSError, ValueError):
        return None
    delta_days = (moment.date() - today).days
    if delta_days <= 0:
        return moment.strftime("today %H:%M")
    if delta_days == 1:
        return moment.strftime("tomorrow %H:%M")
    if delta_days < 7:
        return moment.strftime("%a %H:%M")
    return moment.strftime("%b %-d")


def _headline(remaining, resets_label, status, burn_rate, allowance,
              exhausts_label, delta, unit, rate_source=None):
    """One short line stating the situation. This is the product."""
    if status == STATUS_EXHAUSTED:
        return (f"Exhausted · resets {resets_label}" if resets_label
                else "Exhausted")

    left = f"{remaining:.0f}% left"
    head = f"{left} · {resets_label}" if resets_label else left
    # An estimate off token history is worth marking; a measured rate is not.
    estimated = rate_source == "estimated"
    rate = f"~{_fmt_rate(burn_rate)}" if estimated else _fmt_rate(burn_rate)

    if status == STATUS_CRITICAL and exhausts_label and burn_rate:
        return f"{head}. Out {exhausts_label} · {rate}%/{unit}"
    if burn_rate is not None and allowance is not None and status == STATUS_AHEAD:
        return f"{head}. Burn {rate} vs {_fmt_rate(allowance)}%/{unit}"
    if delta is not None and burn_rate is not None:
        return f"{head}. On pace · {_points(delta)}"
    return f"{head}. Collecting history"


def _verdict(status, resets_label, exhausts_label, delta, has_forecast):
    """The one line answering "do I make it to the reset, and if not, when".

    Deliberately not a sentence. It fills a slot next to a stat row rather than
    carrying the numbers itself, so it never repeats what the row already
    shows — that duplication is what made the old copy read as a paragraph.
    `headline` stays the prose version for the board's single caption line and
    for VoiceOver.
    """
    if status == STATUS_EXHAUSTED:
        return f"Spent, back in {resets_label}" if resets_label else "Spent"
    if status == STATUS_CRITICAL:
        return (f"Runs out {exhausts_label}" if exhausts_label
                else "Runs out before reset")
    if not has_forecast:
        return "Collecting history"
    if status == STATUS_AHEAD:
        # "Ahead of pace" cuts both ways to a casual reader — ahead of schedule
        # sounds like good news. "Over" only means the one thing.
        return "Over pace"
    if delta is not None and delta >= 1:
        return f"On track · {delta:.0f}%"
    return "On track"


def compute(provider, pool, payload, *, now=None, points=DEFAULT_POINTS,
            tz=None, rows=None, prior_pct_per_day=None):
    """Burndown for one pool, or None when the pool has no usable reading.

    `rows` overrides the sample lookup (tests, and callers batching one read).
    Pass the pool's whole log, oldest first — not a pre-filtered window.

    `prior_pct_per_day` is a burn estimate derived from token history, used
    only while the window is too fresh to fit a slope. Measured samples always
    win once they exist, and anything resting on the prior is marked
    `rate_source: "estimated"` so the copy can hedge honestly.
    """
    now = time.time() if now is None else float(now)
    reading = quota_samples.extract(provider, pool, payload)
    if reading is None:
        return None

    window_s = reading["window_s"]
    resets_in_s = reading["resets_in_s"]
    used_pct = reading["pct"]
    remaining = max(0.0, 100.0 - used_pct)

    # The pool's whole log, not just this window: the series below selects by
    # sample *time* inside the window anyway — including rows stamped with a
    # forked window_start from resets_in jitter, which equality on the label
    # alone used to hide behind a flat "today only" line — and the grants the
    # chart marks are boundaries between windows, so they need both sides.
    if rows is None:
        rows = quota_samples.read(provider=provider, pool=pool)
    window_start, window_end = quota_samples.window_for(
        now, window_s, resets_in_s, pct=used_pct,
        previous=(rows[-1] if rows else None),
    )

    # The axis ends on the held reset, so the countdown has to come from the
    # same number. Raw `resets_in_s` decays against the clock loosely enough on
    # some sources that reading it straight is how a "6d 23h to reset" caption
    # ends up over an axis that runs out two days earlier.
    resets_in_s = max(0, int(window_end - now))

    # Even-spend position right now. Equivalent to 100 - pace_pct, kept in
    # remaining space so it lines up with the chart.
    pace = oauth_usage.pace_pct(resets_in_s, window_s)
    ideal_remaining = 100.0 - pace if pace is not None else None
    delta = (remaining - ideal_remaining) if ideal_remaining is not None else None

    # Clipped to the window, so the curve can never span a reset. Samples from
    # the other side of one describe a budget that no longer exists.
    series = [
        (int(row["t"]), max(0.0, 100.0 - float(row["pct"])))
        for row in rows
        if row.get("t") is not None and row.get("pct") is not None
        and window_start <= int(row["t"]) <= window_end
    ]
    series.sort(key=lambda p: p[0])
    # The live reading is newer than the newest persisted bucket.
    if not series or series[-1][0] < int(now) - quota_samples.BUCKET_S:
        series.append((int(now), remaining))

    # --- forecast -------------------------------------------------------
    lookback = max(FIT_LOOKBACK_MIN_S, min(FIT_LOOKBACK_MAX_S, window_s // 3))
    # Never reach back past the window's own start. A slice that straddles a
    # reset fits a line through a vertical jump *upward*, which reads as a
    # slope of zero and hides the burn that came after it.
    recent = [p for p in series if p[0] >= max(now - lookback, window_start)]
    span = (recent[-1][0] - recent[0][0]) if len(recent) >= 2 else 0
    slope = None
    if len(recent) >= MIN_FIT_SAMPLES and span >= MIN_FIT_SPAN_S:
        slope = _slope_per_s(recent)

    unit = _rate_unit(window_s)
    per = _rate_seconds(unit)
    burn_rate = None      # remaining-pct consumed per `unit`
    exhausts_at = None
    exhausts_in_s = None
    projected = []
    rate_source = None
    # Fall back to the token-history estimate only while there is no fit.
    rate_per_s = None
    if slope is not None:
        rate_source = "measured"
        rate_per_s = -slope if slope < 0 else 0.0
    elif prior_pct_per_day and prior_pct_per_day > 0:
        rate_source = "estimated"
        rate_per_s = float(prior_pct_per_day) / 86400.0

    if rate_per_s is not None:
        burn_rate = rate_per_s * per
        # Draw the projection only as far as the reset; past that it is moot.
        end = window_end
        if rate_per_s > 0:
            exhausts_in_s = remaining / rate_per_s
            exhausts_at = int(now + exhausts_in_s)
            end = min(exhausts_at, window_end)
        # A flat pace still lands somewhere — level, at the reset — and saying
        # so is not the same as saying nothing. An absent line reads as "no
        # forecast yet", which is the one thing a measured zero is not.
        if end > now:
            projected = [[int(now), round(remaining, 2)],
                         [int(end),
                          round(max(0.0, remaining - rate_per_s * (end - now)),
                                2)]]

    units_left = max(resets_in_s, 1) / per
    allowance = remaining / units_left if units_left > 0 else None
    # Inside the last rate-unit the ratio runs away: 91% with an hour left is
    # not a "2184%/day budget". Past the size of the pool itself the number has
    # stopped saying anything, so drop it and let the headline fall through to
    # points-to-spare, which stays true right up to the reset.
    if allowance is not None and allowance > 100.0:
        allowance = None
    exhausted = remaining <= 0
    if exhausted:
        # Forecasting the exhaustion of an already-exhausted pool is noise.
        exhausts_at = None
        exhausts_in_s = None
        projected = []
    exhausts_before_reset = bool(
        exhausts_in_s is not None and exhausts_in_s < resets_in_s)

    if exhausted:
        status = STATUS_EXHAUSTED
    elif exhausts_before_reset:
        status = STATUS_CRITICAL
    elif delta is not None and delta <= -DEFICIT_PCT:
        status = STATUS_AHEAD
    else:
        status = STATUS_OK

    resets_label = oauth_usage.fmt_resets(resets_in_s)
    exhausts_label = _when(exhausts_at, tz, now)

    return {
        "provider": provider,
        "pool": pool,
        "window_start": window_start,
        "window_end": window_end,
        "window_s": window_s,
        "now": int(now),
        "remaining_pct": _round(remaining),
        "used_pct": _round(used_pct),
        "ideal_remaining_pct": _round(ideal_remaining),
        "delta_pct": _round(delta),
        "in_deficit": bool(delta is not None and delta < 0),
        "exhausted": exhausted,
        "status": status,
        "resets_in_s": resets_in_s,
        "resets_in": resets_label,
        # [[epoch_s, remaining_pct], ...] — ideal is a straight line, so two
        # points is the whole of it.
        "ideal": [[window_start, 100.0], [window_end, 0.0]],
        # Resets granted out of band, newest window last. A scheduled roll is
        # already drawn by the axis; these are the ones that would otherwise
        # look like the chart forgetting yesterday.
        "resets": quota_samples.rolls(
            rows, since=now - quota_samples.ROLL_LOOKBACK_S),
        # Thinned across the range that actually has samples, not across the
        # whole window — a window we only joined halfway through would
        # otherwise spend most of the point budget on empty time.
        "actual": [[t, round(r, 2)]
                   for t, r in _downsample(series, points, series[0][0], now)],
        "projected": projected,
        # Both rates are in `rate_unit`, which tracks the window length: a 5h
        # session is points-per-hour, a weekly window is points-per-day.
        "rate_unit": unit,
        # "measured" from real samples, "estimated" from token history, or
        # None when there is nothing to go on yet.
        "rate_source": rate_source,
        "burn_rate_pct": _round(burn_rate, 2),
        "allowance_pct": _round(allowance, 2),
        "exhausts_at": exhausts_at,
        "exhausts_in_s": None if exhausts_in_s is None else int(exhausts_in_s),
        "exhausts_in": (None if exhausts_in_s is None
                        else oauth_usage.fmt_resets(exhausts_in_s)),
        "exhausts_before_reset": exhausts_before_reset,
        "samples": len(series),
        # Prose, for the board's one caption line and for VoiceOver.
        "headline": _headline(remaining, resets_label, status, burn_rate,
                              allowance, exhausts_label, delta, unit,
                              rate_source),
        # The same situation as a slot: a short phrase that sits above a stat
        # row instead of restating it.
        "verdict": _verdict(status, resets_label, exhausts_label, delta,
                            rate_source is not None),
    }


def compute_all(state, *, now=None, points=DEFAULT_POINTS, tz=None,
                priors=None):
    """Burndowns for every configured pool: {provider: {pool: {...}}}.

    Reads the sample log once per pool. Sources that are off, unconfigured, or
    failing simply do not appear. `priors` maps provider id to a %/day burn
    estimate used only where samples are too thin to fit.

    A source stuck on a stale reading drops out too, once past the blip
    window. Everything this returns is measured from *now* — the countdown, the
    pace delta, the time to exhaustion — so computing it against a reading from
    last night does not produce a slightly old chart, it produces a confident
    wrong one. No chart, plus the staleness the sources list already reports,
    is the honest version.
    """
    now = time.time() if now is None else float(now)
    priors = priors or {}
    out = {}
    for spec in quota_samples.POOLS:
        payload = (state or {}).get(spec.provider)
        if not cache_util.trusted(payload, now):
            continue
        try:
            result = compute(spec.provider, spec.pool, payload,
                             now=now, points=points, tz=tz,
                             prior_pct_per_day=priors.get(spec.provider))
        except Exception as exc:  # a chart must never break the poll tick
            print(f"burndown {spec.provider}.{spec.pool} error:", exc)
            continue
        if result is not None:
            out.setdefault(spec.provider, {})[spec.pool] = result
    return out


def primary(burndowns):
    """The pool most worth showing, ranked by how actionable it is.

    About to run out beats already out: an exhausted pool is a fact you can
    only wait out, while a critical one is still a decision. Ties break toward
    the shorter window, since a 5h session running dry is more actionable than
    a weekly window drifting.
    """
    candidates = [
        result
        for pools in (burndowns or {}).values()
        for result in pools.values()
    ]
    if not candidates:
        return None

    rank = {STATUS_CRITICAL: 0, STATUS_EXHAUSTED: 1,
            STATUS_AHEAD: 2, STATUS_OK: 3}

    def key(result):
        return (
            rank.get(result.get("status"), 4),
            result.get("exhausts_in_s") if result.get("exhausts_in_s") is not None
            else float("inf"),
            result.get("delta_pct") if result.get("delta_pct") is not None
            else float("inf"),
            result.get("window_s") or 0,
        )

    return min(candidates, key=key)
