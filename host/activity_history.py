"""Mixed-source daily activity history for the app and desk display.

The heatmap is deliberately not a Claude chart. Claude has a local session
log, while the other quota sources only expose a sampled daily burn. Those
signals are not comparable as one numeric unit, so a day is scored from the
amount of evidence we have: Claude active minutes plus the number of quota
sources that burned that day. The details keep the native numbers and source
ids for the app's day inspector.

This is a view over existing stores, not another log. Claude retains 400 days;
daily burn retains 30. Empty cells mean "no recorded activity", never a claim
that every provider was idle.
"""

from __future__ import annotations

from datetime import date, timedelta


RETENTION_DAYS = 365
QUOTA_HISTORY_DAYS = 30


def _level_for_minutes(minutes):
    """Map Claude active minutes to the shared five-stop heatmap ramp."""
    try:
        value = int(minutes or 0)
    except (TypeError, ValueError):
        value = 0
    if value <= 0:
        return 0
    if value < 15:
        return 1
    if value < 60:
        return 2
    if value < 180:
        return 3
    return 4


def _date_range(today, days):
    start = today - timedelta(days=days - 1)
    return [start + timedelta(days=i) for i in range(days)]


def _positive_burns(row):
    burns = row.get("burns") if isinstance(row, dict) else None
    if not isinstance(burns, dict):
        burns = {}
        for provider in ("claude", "codex", "cursor"):
            value = row.get(provider) if isinstance(row, dict) else None
            if value is not None:
                burns[provider] = value

    out = {}
    for provider, value in burns.items():
        try:
            value = float(value or 0)
        except (TypeError, ValueError):
            continue
        if value > 0:
            out[str(provider)] = round(value, 2)
    return out


def build(claude_rows=None, burn_rows=None, *, today=None, days=RETENTION_DAYS,
          available_sources=None):
    """Return the sparse mixed-source heatmap payload.

    `claude_rows` and `burn_rows` are oldest-to-newest rows from
    ``claude_history.series`` and ``daily_burn.series``. The full ``levels``
    array is retained for compact clients; ``days`` contains only non-empty
    days so the normal app payload stays small and can explain a tapped cell.
    """
    today = today or date.today()
    days = max(1, int(days))
    dates = _date_range(today, days)
    start = dates[0]
    end = dates[-1]
    by_date = {}

    for row in claude_rows or []:
        if not isinstance(row, dict) or not row.get("date"):
            continue
        by_date.setdefault(str(row["date"]), {})["claude"] = row

    for row in burn_rows or []:
        if not isinstance(row, dict) or not row.get("date"):
            continue
        by_date.setdefault(str(row["date"]), {})["burn"] = row

    sparse = []
    levels = []
    for current in dates:
        key = current.isoformat()
        parts = by_date.get(key) or {}
        claude = parts.get("claude") or {}
        burn_row = parts.get("burn") or {}
        burns = _positive_burns(burn_row)

        minutes = int(claude.get("active_minutes") or 0)
        sessions = int(claude.get("sessions") or 0)
        tokens = int(claude.get("total") or 0)
        cost = round(float(claude.get("cost_usd") or 0), 4)

        sources = []
        if minutes > 0 or sessions > 0 or tokens > 0:
            sources.append("claude")
        # Claude can be represented by either local session evidence or its
        # quota burn; the source id is still one mixed source either way.
        sources.extend(burns)
        sources = sorted(set(sources))

        # Minutes provide depth for the source with real historical events;
        # each other source contributes one more piece of evidence. This keeps
        # the level honest without pretending percentage points equal minutes.
        level = max(_level_for_minutes(minutes), min(4, len(sources)))
        levels.append(level)
        if level == 0:
            continue

        detail = {
            "date": key,
            "level": level,
            "sources": sources,
        }
        if minutes > 0:
            detail["active_minutes"] = minutes
        if sessions > 0:
            detail["sessions"] = sessions
        if tokens > 0:
            detail["tokens"] = tokens
        if cost > 0:
            detail["cost_usd"] = cost
        if burns:
            detail["burns"] = burns
        sparse.append(detail)

    if available_sources is None:
        available = {"claude"}
        for row in burn_rows or []:
            available.update(_positive_burns(row))
        available_sources = sorted(available)
    else:
        available_sources = sorted(set(str(value) for value in available_sources))

    active_keys = {row["date"] for row in sparse}
    streak = 0
    cursor = today
    while cursor.isoformat() in active_keys:
        streak += 1
        cursor -= timedelta(days=1)

    best = max(
        sparse,
        key=lambda row: (int(row.get("level") or 0),
                         int(row.get("active_minutes") or 0)),
        default=None,
    )
    return {
        "source": "mixed",
        "window_days": days,
        "start": start.isoformat(),
        "end": end.isoformat(),
        "start_weekday": start.weekday(),  # Monday = 0, like Swift Calendar
        "levels": levels,
        "days": sparse,
        "active_days": len(sparse),
        "current_streak": streak,
        "best_day": best["date"] if best else None,
        "available_sources": available_sources,
    }
