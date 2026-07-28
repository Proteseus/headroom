"""Stamp every firmware build with a number that moves, plus its source commit.

The board had no way to say what it was running. A reflash could only ever be
*inferred* — esptool verified the write, the thing rebooted, therefore it is
probably new — and that inference is weakest exactly when it matters most:
rebuilding uncommitted work, where the commit hash has not changed and nothing
externally visible distinguishes build N from build N-1.

So the counter is per *build*, not per commit. It ticks whenever PlatformIO
produces a binary, which is the event you actually want to confirm reached the
hardware. The commit and dirty flag ride along to tie a number back to source.

The counter lives outside git on purpose: it describes this machine's build
history, not the tree. Two checkouts disagreeing about it is correct, and the
commit hash is what makes builds comparable across machines.

Because the number changes every build, main.cpp recompiles every build. That
is the cost of the guarantee and it is a few seconds on this project.
"""

import subprocess
from pathlib import Path

Import("env")  # noqa: F821 — injected by PlatformIO

# SCons execs this without __file__, so the project dir comes from the env.
HERE = Path(env.subst("$PROJECT_DIR")).resolve()  # noqa: F821
COUNTER = HERE / ".build_number"
# Nine commits touched firmware/ before builds were numbered. Starting the
# counter past them keeps the number from reading as "never tracked" and marks
# where the counting began.
SEED = 9


def _git(*args, default=""):
    try:
        out = subprocess.run(
            ["git", *args], cwd=str(HERE), capture_output=True, text=True,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return default
    return out.stdout.strip() if out.returncode == 0 else default


def _next_build():
    try:
        current = int(COUNTER.read_text().strip())
    except (OSError, ValueError):
        current = SEED
    nxt = current + 1
    try:
        COUNTER.write_text(f"{nxt}\n")
    except OSError:
        pass  # a read-only tree still builds, it just stops counting
    return nxt


# `pio run -t upload` evaluates this script once for the build phase and again
# for the upload phase, against the same env. Unguarded that bumps the counter
# twice and defines FW_VERSION twice on the compiler line, leaving the binary's
# identity to whichever -D the compiler happens to honour last. Stamp once.
_STAMPED = "HEADROOM_FW_VERSION"
if env.get(_STAMPED):  # noqa: F821
    Return()  # noqa: F821 — SCons early-exit, not Python's return

build = _next_build()
commit = _git("rev-parse", "--short", "HEAD", default="nogit")
# Only firmware/ dirt can change this binary, so host-side edits do not make a
# build "dirty" and send you hunting for a difference that isn't there.
dirty = bool(_git("status", "--porcelain", "--", str(HERE)))

# Hyphen rather than "+": this string is sent as a query parameter, and "+"
# decodes to a space on the host side.
version = f"{build}.{commit}{'-dirty' if dirty else ''}"

env.Append(CPPDEFINES=[  # noqa: F821
    ("FW_BUILD", build),
    ("FW_VERSION", env.StringifyMacro(version)),  # noqa: F821
])
env[_STAMPED] = version  # noqa: F821


def _record_flashed(*_args, **_kwargs):
    """Remember which build actually reached the board.

    Because the counter moves on every build, the repo's number runs ahead of
    the hardware more or less permanently — a compile you never flashed still
    burns one. So "the board says 11" needs something to be equal *to*, and
    that something is the last build an upload succeeded on, not the last one
    the compiler emitted.
    """
    try:
        (HERE / ".flashed_build").write_text(f"{version}\n")
    except OSError:
        pass
    print(f"flashed {version}")


env.AddPostAction("upload", _record_flashed)  # noqa: F821

print(f"firmware build {version}")
