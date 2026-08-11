# Headroom for the ESP32 desk display

Optional always-on glance. Same `/usage` feed as the menu bar and phone — **not
part of the core install**. The Mac host + menu bar (and optional iPhone /
Watch) are the product; this board is the desk curiosity that paints the same
numbers.

```
Mac host ──Wi-Fi HTTP──▶ board   (preferred)
Mac host ──USB CDC────▶ board   (hotel / no LAN fallback)
```

## Supported board

Firmware in this repo targets **one** SKU:

| | |
|---|---|
| **Product** | [Waveshare ESP32-S3-Touch-AMOLED-1.8](https://www.waveshare.com/esp32-s3-touch-amoled-1.8.htm) |
| **SoC** | ESP32-S3R8 (Wi‑Fi + BLE, 8MB PSRAM, 16MB flash) |
| **Panel** | 1.8″ AMOLED, **368×448**, SH8601 over QSPI |
| **Touch** | FT3168 / FT3x68 (some V2 demos use CST816T at `0x15`) |
| **PMU** | AXP2101 (battery charge + fuel gauge on the MX1.25 header) |
| **Expander** | TCA9554 (LCD / touch reset + DSI power) — usually `0x20`, some units `0x21` |
| **Extras** | QMI8658 IMU, PCF85063 RTC, ES8311 audio, BOOT + PWR buttons |

Pins and bring-up order live in `firmware/src/pin_config.h` and
`firmware/src/main.cpp`, matched to Waveshare’s Arduino demo for **this**
board. Sibling Waveshare sizes (1.75″, 2.06″, etc.) are **not** drop-in —
different resolution, often different panel/PMU wiring.

Optional 3.7V LiPo on the MX1.25 header; USB-C alone is enough for desk use.
Bottom-left power glyph reads the AXP2101 (plug on VBUS, cell + % when a
battery is fitted).

**Black screen?** Try `TCA9554_ADDR = 0x21` in `pin_config.h` (Waveshare issue
#3). `pio device monitor` and the host’s USB bridge cannot share the port —
use `./scripts/flash-esp32.sh`, which refuses to race.

## Flash

Needs [PlatformIO](https://platformio.org/).

1. `cp firmware/src/config_example.h firmware/src/config.h` — Wi‑Fi SSIDs +
   Mac hostname (`scutil --get LocalHostName`) or fallback IP.
2. Paste the **host token** into `HOST_TOKEN` (`~/.headroom/token` after first
   host start — **not** the mobile token).
3. Prefer `./scripts/flash-esp32.sh` (checks the serial port is free). Or:
   `cd firmware && pio run -t upload && pio device monitor`.

Wi-Fi is the default transport and the normal LaunchAgent does not claim
`/dev/cu.usbmodem*`. For the offline USB fallback, start the host with
`HEADROOM_ENABLE_USB=1`; stop that host before flashing or monitoring:

```bash
launchctl bootout gui/$(id -u)/com.centaur-labs.headroom
./scripts/flash-esp32.sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.centaur-labs.headroom.plist
```

Update the Mac host before flashing: the board reads its three providers from
`/usage?view=device` → `providers[]`, which a host older than 1.0.9 does not
send. A board that gets no providers says so on the glance rather than guessing.

## Using it

Wi‑Fi first; USB CDC when LAN fails. **Tap** a glance slot for detail; tap the
header to cycle the lower pane; **hold** a glance slot to switch the upper
half between Rings and Pace; **long-press** empty chrome → `POST /sync/refresh`.
BOOT returns home.

A glance slot answers on release, not on the way down, because the same press
is what holds. The gap is one fingertip lift — under a tenth of the 400ms hold.

| Corner | Meaning |
|---|---|
| Top-right | Host `updated` clock |
| Bottom-right | Link glyph — Wi‑Fi arcs or USB cable |
| Bottom-left | Power — plug on VBUS; battery fill + % when a cell is present; bolt while charging |

### Rings or Pace

The upper half has the two readings the macOS menu-bar icon has, and the board
keeps its own choice in NVS — the Mac's Settings → General picker does not
travel here.

| Style | What each slot shows |
|---|---|
| **Rings** (default) | Concentric bands, arc = used, white dot = even spend ([docs/rings.md](rings.md)) |
| **Pace** | One pill per provider with a line at even spend, and an accent mark riding `tanh((used − pace) / 8)` above the line when over, below when under |

Pace drops the arc, so it answers only whether the burn is ahead or behind —
the same trade the menu bar makes, and the same curve, so a gap of 8 points
lands near halfway to the end of the pill either way. It reads the provider's
longer window, which is the pool the menu bar takes too. A provider with no
pace draws a dimmer pill, no line and no mark, rather than a mark at zero.

The even-spend line stops at each pill. The menu bar carries one rail across
all three slots, which it can afford at 18pt; at 448px the same rail read as a
shared scale, and the three slots do not share one — each pill is its own
provider against its own window.

Preview both without a reflash:

```bash
.venv-shots/bin/python scripts/render_esp32_preview.py --input docs/demo_usage.json --glance-style pace --raw --out /tmp/pace.png
```

## Reset celebration

When a provider's quota window rolls, the board takes over the screen for about
2.4 seconds with an accent-tinted confetti burst. The provider's configured
accent supplies all of the particle shades. To test it remotely from the Mac
or another private-network machine, send the host token and optionally name a
provider slot:

```bash
curl -sS -X POST \
  -H "X-Headroom-Token: $(cat ~/.headroom/token)" \
  -H 'Content-Type: application/json' \
  -d '{"effect":"reset","provider":"codex"}' \
  http://headroom.local:8737/device/effect
```

The command is picked up on the board's next normal poll. Omit `provider` to
use the first selected model's accent. The endpoint is token-authenticated and
private-network-only.

## Auto brightness

Follows local solar times from lat/lon (Amsterdam defaults) plus a fixed
bedtime. Knobs live in `firmware/src/config.h` (see `config_example.h`).

| Window | Level |
|---|---|
| Sunrise − 30 min → evening dim | 100% (`BRIGHTNESS_DAY`, default 200) |
| Sunset + 30 min → bedtime | ~30% |
| Bedtime (default 22:00) → sunrise − 30 min | ~10% |

Winter keeps a long evening plateau when dusk is early. If sunset + 30 min
would land after bedtime (late summer), evening is skipped and the panel goes
day → night at bedtime — so August does not put a one-minute 30% step after
lights-out.

Clock from SNTP when Wi‑Fi is up (`TIMEZONE_POSIX`, default Europe/Amsterdam),
else the host’s `updated` stamp advanced by millis. Override `LATITUDE` /
`LONGITUDE` / `BRIGHTNESS_BEDTIME_MIN` / the percents, or set
`BRIGHTNESS_AUTO 0` to freeze at day level.

## Token

The board uses the **host token** (`~/.headroom/token`), same as any generic
LAN client. Do not paste the iPhone **mobile token**. See
[setup.md](setup.md#tokens-host-vs-mobile).

## Troubleshooting

| Symptom | Fix |
|---|---|
| **NO HOST** on the panel | The board names the failing half — SSID, address, token, why. `pio device monitor` prints the same plus `curl` checks for the Mac |
| Flash fights the cable | Host LaunchAgent holds the port — bootout / flash / bootstrap as above, or use `./scripts/flash-esp32.sh` which refuses when busy |
| Green fringe / black panel | Expander address or bring-up order — see Supported board |
| Stays bright at night | Wait for SNTP or a successful `/usage` so the clock is known; confirm `BRIGHTNESS_AUTO 1` |

More: [troubleshooting.md](troubleshooting.md).
