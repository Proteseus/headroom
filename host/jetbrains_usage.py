"""JetBrains AI Assistant quota (local XML).

Reads the most recently modified `AIAssistantQuotaManager2.xml` under
~/Library/Application Support/JetBrains/*/options/ (and Android Studio under
Google/). CodexBar-equivalent; stdlib only.
"""

from __future__ import annotations

import html
import json
import os
import time
import xml.etree.ElementTree as ET
from pathlib import Path

import cache_util
import quota_util

CACHE_TTL_S = 60
FAIL_TTL_S = 20
DISK = "jetbrains_quota"
MONTH_WINDOW_S = 30 * 86400

_JB_ROOTS = (
    os.path.expanduser("~/Library/Application Support/JetBrains"),
    os.path.expanduser("~/Library/Application Support/Google"),
)

_cache = {"t": 0.0, "data": None, "err": None}
_EMPTY = {"ok": False, "plan": None, "month": None}


def _quota_files():
    out = []
    for root in _JB_ROOTS:
        base = Path(root)
        if not base.is_dir():
            continue
        for path in base.glob("*/options/AIAssistantQuotaManager2.xml"):
            try:
                mtime = path.stat().st_mtime
            except OSError:
                continue
            out.append((mtime, path))
    out.sort(key=lambda item: item[0], reverse=True)
    return [path for _, path in out]


def signed_in():
    return bool(_quota_files())


def _parse_attr_json(raw):
    if not raw:
        return None
    text = html.unescape(str(raw))
    try:
        return json.loads(text)
    except (json.JSONDecodeError, TypeError):
        return None


def _parse_file(path: Path):
    try:
        tree = ET.parse(path)
    except (OSError, ET.ParseError):
        return None
    root = tree.getroot()
    # Prefer the component that holds quotaInfo.
    node = None
    for candidate in root.iter():
        if candidate.attrib.get("quotaInfo") or candidate.attrib.get("nextRefill"):
            node = candidate
            break
    if node is None:
        node = root
    quota = _parse_attr_json(node.attrib.get("quotaInfo"))
    refill = _parse_attr_json(node.attrib.get("nextRefill"))
    if not isinstance(quota, dict):
        return None

    maximum = quota.get("maximum")
    available = None
    tariff = quota.get("tariffQuota")
    if isinstance(tariff, dict) and tariff.get("available") is not None:
        available = tariff.get("available")
    current = quota.get("current")
    if available is not None and maximum is not None:
        try:
            used = float(maximum) - float(available)
            pct = quota_util.used_pct(used, maximum)
        except (TypeError, ValueError):
            pct = None
    else:
        pct = quota_util.used_pct(current, maximum)

    resets_in = None
    if isinstance(refill, dict):
        resets_in = quota_util.resets_from_iso(refill.get("next"))
    ide = path.parent.parent.name  # e.g. IntelliJIdea2025.1
    return {
        "ok": pct is not None,
        "plan": ide,
        "error": None if pct is not None else "no JetBrains AI quota yet",
        "month": quota_util.pool(pct, resets_in, MONTH_WINDOW_S),
        "stale": False,
    }


def fetch_quota(force=False):
    now = time.time()
    if (
        not force
        and _cache["data"] is not None
        and now - _cache["t"] < (FAIL_TTL_S if _cache.get("err") else CACHE_TTL_S)
    ):
        return _cache["data"]

    files = _quota_files()
    if not files:
        return cache_util.keep_stale(
            _cache, now, "JetBrains AI not detected", _EMPTY, disk_name=DISK)

    last_err = "could not parse JetBrains AI quota"
    for path in files[:5]:
        try:
            parsed = _parse_file(path)
        except Exception as exc:  # noqa: BLE001 — surface as soft error
            last_err = str(exc)
            continue
        if parsed and parsed.get("ok"):
            cache_util.save_disk(DISK, parsed)
            _cache.update(t=now, data=parsed, err=None)
            return parsed
        if parsed and parsed.get("error"):
            last_err = parsed["error"]

    return cache_util.keep_stale(_cache, now, last_err, _EMPTY, disk_name=DISK)
