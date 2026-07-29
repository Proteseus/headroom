"""Who this Mac is, stably, across host restarts and renames.

Multi-Mac needs a name for each machine and an id that outlives it. The two
are deliberately separate: the id is what peer files are keyed by and must
never change, the name is what a person reads and should follow the Mac's
name in System Settings the moment they change it.

`IOPlatformUUID` would have saved a file, but it is the same value every
vendor uses to fingerprint a machine, and this one gets written into a folder
that syncs. A random uuid4 identifies a Headroom install, which is all the
sync needs, and tells a reader nothing about the hardware.

Stdlib only.
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import threading
import uuid

STORE_PATH = os.path.expanduser("~/.headroom/machine.json")

_lock = threading.Lock()
_cache = None


def _computer_name():
    """The Mac's name as System Settings shows it, else its hostname.

    `scutil --get ComputerName` returns the friendly name ("Studio"), while
    `gethostname()` returns the DNS-safe mangling of it ("Studio.local", or
    "studios-mac-mini"). Prefer the former and keep the latter as the fallback
    for a non-Mac host or a stripped-down environment.
    """
    try:
        result = subprocess.run(
            ["/usr/sbin/scutil", "--get", "ComputerName"],
            capture_output=True, text=True, timeout=5,
        )
        name = (result.stdout or "").strip()
        if result.returncode == 0 and name:
            return name[:64]
    except (OSError, subprocess.SubprocessError):
        pass
    return (socket.gethostname().split(".", 1)[0] or "Mac")[:64]


def _load():
    try:
        with open(STORE_PATH) as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def _save(data):
    folder = os.path.dirname(STORE_PATH)
    os.makedirs(folder, exist_ok=True)
    tmp = STORE_PATH + ".tmp"
    with open(tmp, "w") as handle:
        json.dump(data, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.replace(tmp, STORE_PATH)


def reload():
    """Drop the cache (tests, or after the file is edited by hand)."""
    global _cache
    with _lock:
        _cache = None


def machine_id():
    """This install's stable id, minted on first call."""
    global _cache
    with _lock:
        if _cache is None:
            data = _load()
            stored = data.get("id")
            if not isinstance(stored, str) or len(stored) < 8:
                stored = uuid.uuid4().hex
                data["id"] = stored
                try:
                    _save(data)
                except OSError:
                    # An unwritable home is not worth refusing to serve over.
                    # The id lasts this process and sync sits out the round.
                    pass
            _cache = data
        return _cache["id"]


def display_name():
    """What to print for this Mac. Read live so a rename shows up."""
    return _computer_name()


def describe():
    """{'id', 'name'} for the beacon."""
    return {"id": machine_id(), "name": display_name()}
