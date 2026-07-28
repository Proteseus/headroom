"""One answer to "which host is this?", for the host and everything that ships it.

The menu bar bundles a copy of this directory inside Headroom.app and points
a LaunchAgent at it. Update the app while an older host is already loaded — from
a clone, or from a previous bundle that launchd is happily keeping alive — and
the two disagree in silence: the app decodes fields the running host never
learned to emit, and the popover shows blanks nobody can explain.

`version()` is the release line, bumped by hand in VERSION. `build()` is a
fingerprint of the shipped source, so skew is caught even when nobody remembered
to bump it — which is the common case during development.

The fingerprint rule is a cross-language contract. Swift computes the same value
over the bundled copy in macos/Sources/HostVersion.swift:

  files   entries directly in this directory (no recursion) named VERSION, or
          ending in .py and not starting with test_
  order   sorted by name, byte-wise
  digest  sha256 over, per file: name + "\\n" + byte-length + "\\n" + bytes + "\\n"
  result  first 12 hex characters

Both sides pin the same golden vector — test_host_version.py and
macos/Tests/HostVersionTests.swift. Change the rule in one and a test fails
rather than a user seeing a phantom "up to date".
"""

from __future__ import annotations

import hashlib
import os

HOST_DIR = os.path.dirname(os.path.abspath(__file__))

# A host that can't read its own VERSION is still a host; report it as ancient
# rather than crashing the boot of an otherwise working server.
FALLBACK_VERSION = "0.0.0"

_build_cache: str | None = None


def version(directory: str | None = None) -> str:
    """The release line from VERSION, e.g. "1.0.0"."""
    directory = directory or HOST_DIR
    try:
        with open(os.path.join(directory, "VERSION")) as handle:
            value = handle.read().strip()
    except OSError:
        return FALLBACK_VERSION
    return value or FALLBACK_VERSION


def shipped_files(directory: str | None = None) -> list[str]:
    """The files that define a build: flat, no tests, no __pycache__."""
    directory = directory or HOST_DIR
    try:
        names = os.listdir(directory)
    except OSError:
        return []
    keep = []
    for name in names:
        if not os.path.isfile(os.path.join(directory, name)):
            continue
        if name == "VERSION":
            keep.append(name)
        elif name.endswith(".py") and not name.startswith("test_"):
            keep.append(name)
    return sorted(keep)


def build(directory: str | None = None) -> str:
    """Short fingerprint of the shipped source. See the module docstring."""
    global _build_cache
    if directory is None and _build_cache is not None:
        return _build_cache

    target = directory or HOST_DIR
    digest = hashlib.sha256()
    for name in shipped_files(target):
        try:
            with open(os.path.join(target, name), "rb") as handle:
                data = handle.read()
        except OSError:
            # An unreadable file would make the two sides disagree about the
            # same tree. Rare enough to accept; skipping keeps /health up.
            continue
        digest.update(name.encode("utf-8"))
        digest.update(b"\n")
        digest.update(str(len(data)).encode("ascii"))
        digest.update(b"\n")
        digest.update(data)
        digest.update(b"\n")
    value = digest.hexdigest()[:12]

    if directory is None:
        # The running process loaded this tree at boot; editing files under it
        # afterwards doesn't change what is serving requests.
        _build_cache = value
    return value


def payload(directory: str | None = None) -> dict:
    """The two keys /health carries so clients can spot a stale host."""
    return {"version": version(directory), "build": build(directory)}
