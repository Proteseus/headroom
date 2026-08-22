"""Opt-in USB CDC side-channel for the ESP32 when Wi-Fi isn't available.

Speaks a tiny framed protocol on the same Serial CDC used for debug logs:

  ESP → Mac:  HR GET /usage\\n
              HR POST /sync/refresh\\n
  Mac → ESP:  HR <status> <nbytes>\\n + <nbytes bytes of body> + \\n

Best-effort: missing or busy port is silent; never raises into the HTTP
server. The bridge is deliberately opt-in because opening a serial device
long-term would block flashing, serial monitoring, and other board apps. Set
HEADROOM_ENABLE_USB=1 to enable auto-detection, or set HEADROOM_USB_PORT to
enable the bridge for one explicit device. PlatformIO's serial monitor and
this bridge cannot share the port — if the monitor holds it, USB data falls
back to Wi-Fi on the board.
"""

from __future__ import annotations

import glob
import os
import select
import termios
import threading
import time

PREFIX = "HR "
BAUD = 115200
RETRY_S = 2.0
READ_IDLE_S = 0.25
ENABLE_ENV = "HEADROOM_ENABLE_USB"


_USB_PORT_OFF = {"", "/dev/null", "none", "off", "0", "false"}

_status_lock = threading.Lock()
_active_port = None


def enabled():
    """Whether the host should claim a USB serial port.

    Wi-Fi is the normal transport. An explicit USB port is also an explicit
    request to enable the fallback, which keeps existing debug/travel flows
    usable without making the always-on host own every ESP32 serial port.

    `HEADROOM_USB_PORT=/dev/null` is the documented "stay off the board"
    sentinel for local verification — treat it as off, not as a tty path.
    """
    flag = os.environ.get(ENABLE_ENV)
    if flag is not None:
        return flag.strip().lower() in {"1", "true", "yes", "on"}
    port = os.environ.get("HEADROOM_USB_PORT", "").strip().lower()
    return port not in _USB_PORT_OFF


def is_hr_line(line: str) -> bool:
    return line.startswith(PREFIX)


def parse_request_line(line: str):
    """Return ('GET'|'POST', path) or None if not an HR request."""
    line = line.strip()
    if not is_hr_line(line):
        return None
    rest = line[len(PREFIX):].strip()
    parts = rest.split(None, 1)
    if len(parts) != 2:
        return None
    method, path = parts[0].upper(), parts[1]
    if method not in ("GET", "POST") or not path.startswith("/"):
        return None
    return method, path


def format_reply(status: int, body: bytes = b"") -> bytes:
    """Build a framed HR reply: header line + body + trailing newline."""
    if not isinstance(body, (bytes, bytearray)):
        raise TypeError("body must be bytes")
    header = f"{PREFIX}{int(status)} {len(body)}\n".encode("ascii")
    return header + bytes(body) + b"\n"


def candidate_ports(override=None):
    """Return serial device paths to try (override wins, else auto-detect)."""
    if override:
        return [override] if override.strip().lower() not in _USB_PORT_OFF else []
    env = os.environ.get("HEADROOM_USB_PORT", "").strip()
    if env:
        if env.lower() in _USB_PORT_OFF:
            return []
        return [env]
    ports = sorted(glob.glob("/dev/cu.usbmodem*"))
    ports += sorted(
        p for p in glob.glob("/dev/cu.usbserial*") if p not in ports
    )
    return ports


def status_payload():
    """Return transport state for the local macOS Settings surface."""
    with _status_lock:
        active = _active_port
    return {
        "enabled": enabled(),
        "ports": candidate_ports(),
        "active_port": active,
    }


def _set_active_port(path):
    global _active_port
    with _status_lock:
        _active_port = path


def _configure_tty(fd, baud=BAUD):
    attrs = termios.tcgetattr(fd)
    # iflag, oflag, cflag, lflag, ispeed, ospeed, cc
    attrs[0] = 0  # raw input
    attrs[1] = 0
    attrs[3] = 0  # non-canonical, no echo
    attrs[2] |= termios.CLOCAL | termios.CREAD
    attrs[2] &= ~(termios.PARENB | termios.CSTOPB | termios.CSIZE)
    attrs[2] |= termios.CS8
    try:
        speed = getattr(termios, f"B{baud}")
    except AttributeError:
        speed = termios.B115200
    attrs[4] = speed
    attrs[5] = speed
    attrs[6][termios.VMIN] = 0
    attrs[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    termios.tcflush(fd, termios.TCIOFLUSH)


def open_port(path, baud=BAUD):
    """Open a cu.* device for exclusive R/W. Raises OSError on failure."""
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        _configure_tty(fd, baud=baud)
    except Exception:
        os.close(fd)
        raise
    return fd


def _read_available(fd, buf: bytearray, deadline: float) -> bool:
    """Append available bytes until deadline. Returns False on hard error."""
    while time.monotonic() < deadline:
        try:
            ready, _, _ = select.select([fd], [], [], READ_IDLE_S)
        except (ValueError, OSError):
            return False
        if not ready:
            continue
        try:
            chunk = os.read(fd, 4096)
        except BlockingIOError:
            continue
        except OSError:
            return False
        if not chunk:
            return False  # device gone
        buf.extend(chunk)
        return True
    return True


def _write_all(fd, data: bytes, timeout_s: float = 5.0) -> bool:
    """Write all bytes on a non-blocking fd. Partial writes are normal."""
    view = memoryview(data)
    deadline = time.monotonic() + timeout_s
    while len(view):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return False
        try:
            _, ready, _ = select.select([], [fd], [], min(0.5, remaining))
        except (ValueError, OSError):
            return False
        if not ready:
            continue
        try:
            n = os.write(fd, view)
        except BlockingIOError:
            continue
        except OSError:
            return False
        if n <= 0:
            return False
        view = view[n:]
    return True


def _pop_line(buf: bytearray):
    """Pop one newline-terminated line (str) or None."""
    nl = buf.find(b"\n")
    if nl < 0:
        return None
    raw = bytes(buf[:nl])
    del buf[: nl + 1]
    if raw.endswith(b"\r"):
        raw = raw[:-1]
    try:
        return raw.decode("utf-8", errors="replace")
    except Exception:
        return None


def handle_request(method, path, get_usage, on_sync_refresh,
                   on_device=None) -> bytes:
    """Dispatch one HR request to host callbacks; return framed reply bytes.

    The board hangs its build identity off the query string, so routing is on
    the path alone. `on_device` receives the raw query rather than parsed
    params: this module stays a transport and leaves meaning to the caller.
    """
    route, _, query = path.partition("?")
    if on_device is not None and query:
        try:
            on_device(query)
        except Exception as exc:   # a bad report must not cost a reply
            print(f"usb_bridge device note error: {exc}", flush=True)
    if method == "GET" and route == "/usage":
        body = get_usage()
        if not isinstance(body, (bytes, bytearray)):
            body = b""
        return format_reply(200, bytes(body))
    if method == "POST" and route == "/sync/refresh":
        on_sync_refresh()
        return format_reply(202, b"")
    return format_reply(404, b"")


def _serve_fd(fd, get_usage, on_sync_refresh, stop_event: threading.Event,
              on_device=None):
    buf = bytearray()
    while not stop_event.is_set():
        if not _read_available(fd, buf, time.monotonic() + READ_IDLE_S):
            return
        while True:
            line = _pop_line(buf)
            if line is None:
                break
            req = parse_request_line(line)
            if req is None:
                continue
            method, path = req
            try:
                reply = handle_request(
                    method, path, get_usage, on_sync_refresh, on_device)
            except Exception as exc:
                print(f"usb_bridge handler error: {exc}", flush=True)
                reply = format_reply(500, b"")
            print(f"usb_bridge {method} {path} → {len(reply)}B", flush=True)
            if not _write_all(fd, reply):
                print("usb_bridge write failed", flush=True)
                return
            # Cap buffer growth from spam
            if len(buf) > 64 * 1024:
                del buf[:-4096]


def run(get_usage, on_sync_refresh, port=None, stop_event=None,
        on_device=None):
    """Daemon loop: find a board, serve HR requests, retry forever.

    get_usage() -> bytes   compact JSON body for /usage
    on_sync_refresh()      kick the same force-refresh as HTTP POST
    on_device(query)       raw query string off a board request, for build id
    """
    if stop_event is None:
        stop_event = threading.Event()
    announced = None
    while not stop_event.is_set():
        ports = candidate_ports(override=port)
        opened = False
        for path in ports:
            fd = None
            try:
                fd = open_port(path)
            except OSError:
                continue
            opened = True
            if announced != path:
                print(f"usb_bridge listening on {path}", flush=True)
                announced = path
            _set_active_port(path)
            try:
                _serve_fd(fd, get_usage, on_sync_refresh, stop_event,
                          on_device)
            finally:
                _set_active_port(None)
                try:
                    os.close(fd)
                except OSError:
                    pass
            if announced == path:
                print(f"usb_bridge closed {path}", flush=True)
                announced = None
            break
        if not opened:
            announced = None
        stop_event.wait(RETRY_S)
