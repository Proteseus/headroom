"""Exit when the process that spawned this host goes away.

The menu bar app can own the host's lifecycle instead of launchd, so that
quitting Headroom stops the host too. A spawned child does not die with its
parent on macOS: there is no `PR_SET_PDEATHSIG`, and `applicationWillTerminate`
does not run on a crash or a force quit. The child is reparented to launchd and
keeps :8737 open.

That orphan is worse than a leak. The next app launch probes the port, finds a
host answering, and `waitUntilReady` reports `foreign` because the build
fingerprint belongs to nobody it started. The app then serves a document from a
process no one can stop from the UI.

So the app passes `--exit-with-pid <its own pid>` and this module watches it.

Nothing here runs under the LaunchAgent lifecycle. launchd is the parent there,
launchd does not exit, and the flag is absent anyway.
"""

from __future__ import annotations

import os
import threading
import time

# Slow enough to cost nothing, fast enough that a relaunch after a force quit
# does not race the old host for the port. App relaunch takes longer than this.
DEFAULT_INTERVAL_S = 2.0


def parent_alive(pid: int) -> bool:
    """True while `pid` names a live process this host could signal.

    Signal 0 checks for existence without delivering anything. Three failures
    all mean the parent we were given is gone:

    - `ProcessLookupError`: no such process.
    - `PermissionError`: the pid exists but belongs to someone else, which on a
      single-user Mac means it was recycled after our parent exited.
    - anything else `OSError`: unknown, and staying alive on an unknown is how
      an orphan holds the port forever.

    A non-positive pid is not a process. `os.kill(0, 0)` signals the whole
    process group, which would report our own liveness and never exit.
    """
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except (ProcessLookupError, PermissionError):
        return False
    except OSError:
        return False
    return True


def watch(pid, on_gone, interval=DEFAULT_INTERVAL_S, alive=parent_alive,
          sleep=time.sleep):
    """Block until `pid` disappears, then call `on_gone` once.

    Checks before the first sleep, so a parent that died between spawn and here
    is caught immediately rather than after one interval.

    `alive` and `sleep` are injected for the tests. Nothing else passes them.
    """
    while alive(pid):
        sleep(interval)
    on_gone()


def start(pid, on_gone, interval=DEFAULT_INTERVAL_S):
    """Run `watch` on a daemon thread. Returns the thread for the tests."""
    thread = threading.Thread(
        target=watch,
        args=(pid, on_gone),
        kwargs={"interval": interval},
        name="parent-watch",
        daemon=True,
    )
    thread.start()
    return thread
