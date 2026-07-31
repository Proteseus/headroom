"""What a meter's level and headroom are, one function per kind.

[docs/metering.md](../docs/metering.md) is the design; this is the arithmetic.
Every function here is pure and none of them raise: a meter whose numbers this
cannot read comes back `(None, None)`, and a client draws nothing for it — the
same thing every surface already does for a provider that is off or has not
been fetched yet.

Two numbers, because two is what every kind can answer:

| | |
|---|---|
| `level` | `0.0`–`1.0`, how much of the thing is spent |
| `headroom` | how much is left, **in its own unit** |

`level` is null wherever there is no denominator. A count of credits has no
"out of" — inventing one would draw a full meter for someone holding none, and
a wrong full meter is worse than an empty space.

`headroom` is where the kinds genuinely differ, so it carries its unit with it:
percentage points for a window, credits for a grant, dollars for anything
billed. That is the whole reason it is an object rather than a number.

It carries `value` and `unit` and deliberately **not** a label. A label is
copy, copy lives in `Shared/HeadroomCopy.swift` and `docs/glossary.md` and is
checked by `scripts/check-glossary-copy.sh`; a number and a unit are data. The
formatted durations already on the wire (`resets_in`) are not a precedent for
labels — formatting a duration is not naming a concept.

Stdlib only.
"""

from __future__ import annotations

import sources_config

# What a headroom value is counted in. The set is small on purpose: a unit a
# client does not recognise is a number it cannot label, so adding one is a
# client change, not just a host change.
UNIT_PCT = "pct"
UNIT_COUNT = "count"
UNIT_USD = "usd"
UNITS = (UNIT_PCT, UNIT_COUNT, UNIT_USD)


def _number(value):
    """The value if it is a real number, else None. Guards against bools."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return value


def _window(bucket):
    """A percentage of a pool that refills.

    `pct` is percent *used*, so headroom is what is left of the hundred.
    Clamped because a provider that reports 104% has told us something true
    about the account and nothing useful about a gauge.
    """
    pct = _number(bucket.get("pct"))
    if pct is None:
        return None, None
    level = min(1.0, max(0.0, pct / 100.0))
    return round(level, 4), {
        "value": round(min(100.0, max(0.0, 100.0 - pct)), 1),
        "unit": UNIT_PCT,
    }


def _grant(bucket):
    """Countable items, each with its own expiry.

    No level: two credits out of nothing is not a fraction. The count is the
    whole reading, and the clock is per item rather than per meter — see
    `next_expiry_s`.
    """
    count = _number(bucket.get("available"))
    if count is None:
        return None, None
    return None, {"value": int(count), "unit": UNIT_COUNT}


_BY_KIND = {
    sources_config.KIND_WINDOW: _window,
    sources_config.KIND_GRANT: _grant,
}


def readings(spec, bucket):
    """`(level, headroom)` for one meter, from its slice of the payload.

    A kind with no function here reads as unmeasured rather than as an error:
    the kind is declared, its fetcher has not landed, and a client that draws
    nothing is correct until it does.
    """
    if not isinstance(bucket, dict):
        return None, None
    fn = _BY_KIND.get(spec.kind)
    if fn is None:
        return None, None
    return fn(bucket)


def next_expiry_s(bucket):
    """Seconds until the soonest item in a grant expires, or None.

    Deliberately not folded into `resets_in_s`. A reset is relief arriving and
    an expiry is value leaving; they run the same direction on a clock and
    mean opposite things, and a client that reads one as the other counts down
    to good news that is actually a deadline.

    `codex_usage._parse_reset_credits` already sorts soonest-first, so this
    reads the head rather than re-sorting — but it tolerates an unsorted list,
    because that ordering is a detail of one fetcher and not a contract.
    """
    if not isinstance(bucket, dict):
        return None
    soonest = None
    for item in bucket.get("credits") or []:
        if not isinstance(item, dict):
            continue
        left = _number(item.get("expires_in_s"))
        if left is None:
            continue
        if soonest is None or left < soonest:
            soonest = left
    return None if soonest is None else int(max(0, soonest))
