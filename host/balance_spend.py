"""Shared spend-series math for prepaid balance sources.

OpenRouter (analytics) and AI Gateway (report) both produce a day → USD map.
This module turns that into the leaf shape: today, period total, trailing
average, runway days, and sorted day rows. Stdlib only.
"""

from __future__ import annotations

from datetime import date, datetime, timedelta, timezone


PERIOD_DAYS = 30
TOP_MODELS = 8
# Average daily burn over this many calendar days of the series (including
# quiet days). Runway = remaining / avg. Too short and one spike lies; too
# long and a topped-up pot looks immortal after a quiet stretch.
TRAIL_DAYS = 7


def _as_float(value):
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)
    try:
        return float(str(value).strip())
    except (TypeError, ValueError):
        return None


def _parse_day(value):
    if isinstance(value, date) and not isinstance(value, datetime):
        return value
    text = str(value or "").strip()
    if not text:
        return None
    # Accept YYYY-MM-DD or an ISO datetime prefix.
    try:
        return date.fromisoformat(text[:10])
    except ValueError:
        return None


def utc_today():
    return datetime.now(timezone.utc).date()


def period_bounds(days=PERIOD_DAYS, today=None):
    """Inclusive start/end dates for a trailing window ending today (UTC)."""
    end = today or utc_today()
    start = end - timedelta(days=max(0, int(days) - 1))
    return start, end


def normalize_day_rows(rows):
    """Collapse arbitrary day/usd pairs into sorted unique day rows."""
    by_day = {}
    for row in rows or []:
        if not isinstance(row, dict):
            continue
        day = _parse_day(row.get("day") or row.get("date") or row.get("d"))
        usd = _as_float(row.get("usd") if "usd" in row else row.get("total_usage"))
        if day is None or usd is None:
            continue
        by_day[day] = by_day.get(day, 0.0) + max(0.0, usd)
    return [
        {"day": day.isoformat(), "usd": round(usd, 4)}
        for day, usd in sorted(by_day.items())
    ]


def normalize_model_rows(rows, limit=TOP_MODELS):
    out = []
    for row in rows or []:
        if not isinstance(row, dict):
            continue
        model_id = str(
            row.get("id") or row.get("model") or row.get("title") or ""
        ).strip()
        if not model_id:
            continue
        usd = _as_float(row.get("usd") if "usd" in row else row.get("total_usage"))
        if usd is None:
            continue
        title = str(row.get("title") or model_id).strip() or model_id
        requests = row.get("requests")
        if requests is None:
            requests = row.get("request_count")
        req_n = None
        if requests is not None:
            try:
                req_n = int(float(requests))
            except (TypeError, ValueError):
                req_n = None
        out.append({
            "id": model_id,
            "title": title,
            "usd": round(max(0.0, usd), 4),
            "requests": req_n,
        })
    out.sort(key=lambda r: (-r["usd"], r["id"]))
    return out[: max(0, int(limit))]


def normalize_key_rows(rows):
    out = []
    for row in rows or []:
        if not isinstance(row, dict):
            continue
        name = str(row.get("name") or row.get("label") or "").strip()
        if not name:
            continue
        entry = {"name": name}
        for src, dest in (
            ("usd_daily", "usd_daily"),
            ("usage_daily", "usd_daily"),
            ("usd_weekly", "usd_weekly"),
            ("usage_weekly", "usd_weekly"),
            ("usd_monthly", "usd_monthly"),
            ("usage_monthly", "usd_monthly"),
        ):
            if dest in entry:
                continue
            val = _as_float(row.get(src))
            if val is not None:
                entry[dest] = round(max(0.0, val), 4)
        if len(entry) == 1:
            continue
        out.append(entry)
    out.sort(key=lambda r: (-(r.get("usd_monthly") or r.get("usd_daily") or 0), r["name"]))
    return out


def build_spend(
    *,
    remaining_usd=None,
    by_day=None,
    by_model=None,
    by_key=None,
    period_days=PERIOD_DAYS,
    today=None,
    report_error=None,
):
    """Assemble the leaf spend object from normalized inputs."""
    today = today or utc_today()
    days = normalize_day_rows(by_day)
    by_day_map = {row["day"]: row["usd"] for row in days}
    today_key = today.isoformat()
    today_usd = by_day_map.get(today_key)

    # Fill the trailing window so quiet days count as $0 toward the average.
    start, _end = period_bounds(period_days, today=today)
    filled = []
    cursor = start
    while cursor <= today:
        key = cursor.isoformat()
        filled.append({"day": key, "usd": round(by_day_map.get(key, 0.0), 4)})
        cursor += timedelta(days=1)

    period_usd = round(sum(row["usd"] for row in filled), 4)
    trail_start = today - timedelta(days=TRAIL_DAYS - 1)
    trail = [
        row["usd"] for row in filled
        if date.fromisoformat(row["day"]) >= trail_start
    ]
    avg_daily = round(sum(trail) / len(trail), 4) if trail else None

    runway = None
    rem = _as_float(remaining_usd)
    if rem is not None and avg_daily is not None and avg_daily > 0:
        runway = round(max(0.0, rem) / avg_daily, 1)

    spend = {
        "today_usd": None if today_usd is None else round(today_usd, 4),
        "period_days": int(period_days),
        "period_usd": period_usd,
        "avg_daily_usd": avg_daily,
        "runway_days": runway,
        "by_day": filled,
        "by_model": normalize_model_rows(by_model),
    }
    keys = normalize_key_rows(by_key)
    if keys:
        spend["by_key"] = keys
    if report_error:
        spend["report_error"] = str(report_error)
    return spend
