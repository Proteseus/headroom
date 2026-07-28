"""Trimmed /usage projection for the ESP32.

The full document is ~30KB and the board reads maybe a fifth of it. That cost
is invisible over Wi-Fi but brutal over USB CDC: 30KB at 115200 baud is ~2.6s
of wire time per poll, which is why the cable path needs multi-second timeouts
and why a sync visibly stalls the UI.

This projection keeps only fields `applyUsageJson()` actually consumes, caps
list lengths at what the firmware can store, and drops nulls (ArduinoJson can't
tell an absent key from a null one, and the firmware's `.isNull()` guards treat
them identically). Result is ~4KB.

One source of truth: row caps below must match MAX_* in firmware/src/main.cpp.
Stdlib only.
"""

from __future__ import annotations

# Mirror of firmware/src/main.cpp MAX_DEPLOYS / MAX_COMMITS / MAX_SERVERS.
MAX_DEPLOYS = 6
MAX_COMMITS = 6
MAX_SERVERS = 6
MAX_SOURCES = 8

# The board's three slots. Mirrors sources_config.FOCUS_LIMIT and the
# firmware's MAX_SLOTS: the host picks which providers those are (pinned
# order, enabled only) and ships them in `focus`, so the desk, the menu bar
# and the widget can't disagree about which three.
MAX_PROVIDERS = 3
# Mirror of firmware ProviderQuota::pools — meters drawn per provider.
MAX_POOLS = 3
# What a board flashed before `providers[]` draws, by name.
LEGACY_PROVIDER_IDS = ("claude", "codex", "cursor")

# Legacy Claude-at-top-level / codex / cursor blocks, kept for boards flashed
# before the payload grew `providers[]`. New firmware reads `providers[]` and
# ignores all of this; it costs ~300 bytes and keeps an un-reflashed board on
# the desk working exactly as it did.
CLAUDE_FIELDS = (
    "plan",
    "quota_ok",
    "session_pct",
    "session_pace_pct",
    "session_resets_in",
    "week_pct",
    "week_pace_pct",
    "week_resets_in",
)

CODEX_FIELDS = (
    "ok",
    "plan",
    "session_pct",
    "session_pace_pct",
    "session_resets_in",
    "week_pct",
    "week_pace_pct",
    "week_resets_in",
    "pace_label",
    "runs_out_in",
    "reset_credits_available",
    "reset_credits_expiries",
)

CURSOR_FIELDS = (
    "ok",
    "plan",
    "total_pct",
    "total_pace_pct",
    "auto_pct",
    "auto_pace_pct",
    "api_pct",
    "api_pace_pct",
    "resets_in",
    "pace_label",
    "on_demand_label",
)

# Burndown for the board: one pool per provider (Claude/Codex), or Total+API
# overlaid for Cursor. The ideal line is a straight run from (t0, 100) to
# (t1, 0), so it is derived on the board rather than sent. Keys are short
# because this rides CDC. Secondary series (Cursor API) use *2 suffixes.
MAX_BURNDOWN_POINTS = 24
BURNDOWN_FIELDS = (
    "pool", "status", "t0", "t1", "pts", "proj", "warn", "est", "verdict",
    "pool2", "status2", "pts2", "proj2", "warn2", "est2",
)
# Longest window wins — a weekly shape is worth a chart, a 5h session is noise
# at 368px. Cursor's pools tie on length; Total then API are the two that matter.
BURNDOWN_POOL_ORDER = ("week", "total", "api", "auto", "session")
CURSOR_BURNDOWN_POOLS = ("total", "api")

DEPLOY_FIELDS = ("project", "status", "target", "ago", "branch")
COMMIT_FIELDS = ("repo", "subject", "ago", "branch")
SERVER_FIELDS = ("name", "port", "cmd")
SOURCE_FIELDS = ("id", "title", "enabled", "ok", "stale")


def _pick(src, fields):
    """Copy `fields` from src, skipping keys whose value is None."""
    src = src or {}
    return {k: src[k] for k in fields if src.get(k) is not None}


def _rows(items, fields, limit):
    out = []
    for item in (items or [])[:limit]:
        if isinstance(item, dict):
            out.append(_pick(item, fields))
    return out


def _thin(points, limit):
    """Keep at most `limit` points, preferring shape over even spacing.

    Even index-spacing on a long plateau (Codex idle after an early burn)
    spends the budget on identical y values and erases the drop. Keep first,
    last, and every meaningful remaining-% change, then fill evenly.
    """
    points = [p for p in (points or []) if isinstance(p, (list, tuple)) and len(p) >= 2]
    if len(points) <= limit:
        return [[int(t), round(float(v), 1)] for t, v in points]

    keep = {0, len(points) - 1}
    last_v = float(points[0][1])
    for i in range(1, len(points) - 1):
        v = float(points[i][1])
        if abs(v - last_v) >= 1.0:
            keep.add(i)
            last_v = v

    if len(keep) < limit:
        step = (len(points) - 1) / float(limit - 1)
        for i in range(limit):
            keep.add(int(round(i * step)))
            if len(keep) >= limit:
                break
    elif len(keep) > limit:
        ordered = sorted(keep)
        step = (len(ordered) - 1) / float(limit - 1)
        keep = {ordered[int(round(i * step))] for i in range(limit)}
        keep.add(0)
        keep.add(len(points) - 1)
        while len(keep) > limit:
            mid = sorted(keep)[len(keep) // 2]
            if mid in (0, len(points) - 1):
                break
            keep.discard(mid)

    return [[int(points[i][0]), round(float(points[i][1]), 1)]
            for i in sorted(keep)]


def _proj_for_device(projected):
    """Projection for the board, or [] when it would read as a flat bar.

    A measured-zero pace projects level out to the reset. On Mac that sits
    beside the budget fill; on a ~400px board it is the whole chart.
    """
    proj = _thin(projected, 2)
    if len(proj) >= 2 and abs(float(proj[0][1]) - float(proj[1][1])) < 1.0:
        return []
    return proj


def _board_text(value):
    """Map host copy onto the board's ASCII-only glyph set.

    glcdfont has no middot (·) / fancy dashes — those UTF-8 bytes render as
    two garbage glyphs ("On track XX 15%"). Preview already substitutes; keep
    the live projection matching what the panel can actually draw.
    """
    if not isinstance(value, str) or not value:
        return value
    return (value
            .replace("\u00b7", "-")   # ·
            .replace("\u2013", "-")   # –
            .replace("\u2014", "-"))  # —


def _trim_burndown(pool):
    """Strip one pool to the drawable marks the board understands."""
    if pool.get("window_start") is None or pool.get("window_end") is None:
        return None
    return {
        "pool": pool.get("pool"),
        "status": pool.get("status"),
        "t0": int(pool["window_start"]),
        "t1": int(pool["window_end"]),
        "pts": _thin(pool.get("actual"), MAX_BURNDOWN_POINTS),
        "proj": _proj_for_device(pool.get("projected")),
        "warn": bool(pool.get("exhausts_before_reset")),
        # Projection rests on the token-history estimate rather than measured
        # samples, so the board draws it more faintly.
        "est": pool.get("rate_source") == "estimated",
        # ~25 bytes for the phrase the Mac shows, so the desk and the menu bar
        # answer "do I make it" with the same words.
        "verdict": _board_text(pool.get("verdict")),
    }


def _ordered_pools(pools):
    return sorted(
        (p for p in pools.values() if isinstance(p, dict)),
        key=lambda p: (
            -(p.get("window_s") or 0),
            BURNDOWN_POOL_ORDER.index(p.get("pool"))
            if p.get("pool") in BURNDOWN_POOL_ORDER else len(BURNDOWN_POOL_ORDER),
        ),
    )


def _burndown_for(provider, pools):
    """Pick the pool(s) for the board and strip them to drawable marks.

    Claude/Codex: longest window only. Cursor: Total + API overlaid — they are
    independent budgets on the same billing cycle, and Auto is always empty.
    """
    if not isinstance(pools, dict) or not pools:
        return None
    ordered = _ordered_pools(pools)
    if not ordered:
        return None

    # By base provider, so a second Cursor login ("cursor:work") overlays its
    # API pool the same way the default one does.
    if str(provider).split(":", 1)[0] == "cursor":
        by_name = {p.get("pool"): p for p in ordered}
        primary = by_name.get("total") or next(
            (by_name[name] for name in CURSOR_BURNDOWN_POOLS if name in by_name),
            ordered[0],
        )
        trimmed = _trim_burndown(primary)
        if trimmed is None:
            return None
        secondary = by_name.get("api")
        if secondary is not None and secondary is not primary:
            # Share the primary axis when the two disagree on a few seconds of
            # resets_in jitter — they are the same billing cycle.
            pts = _thin(secondary.get("actual"), MAX_BURNDOWN_POINTS)
            if pts:
                trimmed["pool2"] = secondary.get("pool")
                trimmed["status2"] = secondary.get("status")
                trimmed["pts2"] = pts
                trimmed["proj2"] = _proj_for_device(secondary.get("projected"))
                trimmed["warn2"] = bool(secondary.get("exhausts_before_reset"))
                trimmed["est2"] = secondary.get("rate_source") == "estimated"
        return trimmed

    return _trim_burndown(ordered[0])


def _pool_rows(info):
    """Ring pools for one provider, in the host's declared order.

    Short keys because this rides CDC: t(itle), p(ercent), (pa)c(e),
    r(esets). A pool with no reading is dropped rather than sent as null —
    the board would skip it anyway, and a Codex team plan with no session
    window should not spend bytes saying so.
    """
    pools = info.get("pools")
    if not isinstance(pools, dict):
        return []
    ranked = sorted(
        (
            (pid, pool) for pid, pool in pools.items()
            if isinstance(pool, dict) and pool.get("ring") is not False
        ),
        key=lambda item: (
            item[1]["rank"] if isinstance(item[1].get("rank"), int) else 99,
            item[0],
        ),
    )
    rows = []
    for pid, pool in ranked[:MAX_POOLS]:
        pct = pool.get("pct")
        if pct is None:
            continue
        row = {
            "t": _board_text(pool.get("title") or pid.capitalize()),
            "p": round(float(pct), 1),
        }
        pace = pool.get("pace_pct")
        if pace is not None:
            row["c"] = round(float(pace), 1)
        resets = pool.get("resets_in")
        if resets:
            row["r"] = _board_text(resets)
        rows.append(row)
    return rows


def _provider_note(doc, provider_id):
    """The one extra line the board draws under a provider's meters.

    Today that is only Codex reset credits, which live in the flattened
    `codex` block — built for the default login, so an extra Codex account
    shows its meters without the credits line.
    """
    if provider_id != "codex":
        return None, None
    codex = doc.get("codex") or {}
    available = codex.get("reset_credits_available")
    if available is None:
        return None, None
    expiries = [str(item) for item in
                (codex.get("reset_credits_expiries") or []) if item]
    return (f"{int(available)} reset credits",
            _board_text(" - ".join(expiries)) or None)


def _device_providers(doc):
    """The focus providers, in focus order, with the color to paint them.

    The board used to hardcode Claude / Codex / Cursor and their brand
    colors. Both now come down the wire: which three, in what order, and in
    whose color — so pinning an order or recoloring a row in Mac Settings
    moves the desk gadget too, and an extra account can hold a slot.
    """
    by_id = {
        str(row.get("id")): row
        for row in (doc.get("providers") or []) if isinstance(row, dict)
    }
    rows = []
    for pid in [str(item) for item in (doc.get("focus") or [])]:
        info = by_id.get(pid)
        if info is None or len(rows) >= MAX_PROVIDERS:
            continue
        row = {
            "id": pid,
            "title": _board_text(info.get("title") or pid.capitalize()),
            "ok": bool(info.get("ok")),
            "pools": _pool_rows(info),
        }
        if info.get("accent"):
            row["accent"] = info["accent"]
        if info.get("plan"):
            row["plan"] = _board_text(info["plan"])
        note, note2 = _provider_note(doc, pid)
        if note:
            row["note"] = note
        if note2:
            row["note2"] = note2
        rows.append(row)
    return rows


def build(doc):
    """Project a full rollup document down to the board's subset."""
    doc = doc or {}
    vercel = doc.get("vercel") or {}
    git = doc.get("git") or {}
    local = doc.get("local") or {}

    device = _pick(doc, CLAUDE_FIELDS)
    if doc.get("updated") is not None:
        device["updated"] = doc["updated"]

    device["codex"] = _pick(doc.get("codex"), CODEX_FIELDS)
    device["cursor"] = _pick(doc.get("cursor"), CURSOR_FIELDS)
    device["vercel"] = {
        "ok": bool(vercel.get("ok")),
        "deployments": _rows(
            vercel.get("deployments"), DEPLOY_FIELDS, MAX_DEPLOYS),
    }
    if vercel.get("team"):
        device["vercel"]["team"] = vercel["team"]
    device["git"] = {
        "ok": bool(git.get("ok")),
        "commits": _rows(git.get("commits"), COMMIT_FIELDS, MAX_COMMITS),
    }
    device["local"] = {
        "ok": bool(local.get("ok")),
        "servers": _rows(local.get("servers"), SERVER_FIELDS, MAX_SERVERS),
    }
    if local.get("host"):
        device["local"]["host"] = local["host"]
    device["sources"] = _rows(
        doc.get("sources"), SOURCE_FIELDS, MAX_SOURCES)

    providers = _device_providers(doc)
    if providers:
        device["providers"] = providers

    # Charts only for what the board can show: its three slots, plus the
    # legacy trio an un-reflashed board still draws by name. In the default
    # configuration those are the same three and this costs nothing.
    charted = {row["id"] for row in providers}
    charted.update(LEGACY_PROVIDER_IDS)
    burndown = {}
    for provider, pools in (doc.get("burndown") or {}).items():
        if provider not in charted:
            continue
        trimmed = _burndown_for(provider, pools)
        if trimmed is not None:
            burndown[provider] = trimmed
    if burndown:
        device["burndown"] = burndown
    return device
