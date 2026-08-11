# Headroom for Apple Watch

Two complications and one screen behind them. The watch app is a watchOS
target in `macos/Headroom.xcodeproj`, embedded in the iPhone app — it installs
and updates with the phone, and has no build or release step of its own.

## How the numbers get there

The Mac is the source. The phone is the only thing that can reach it. The
watch can reach neither, and an app group is per-device, so nothing the phone
caches for its own widget is readable from the wrist.

```
Mac host ──LAN──▶ iPhone ──WatchConnectivity──▶ Watch app ──app group──▶ complications
```

The phone forwards the very same `HeadroomWidgetSnapshot` it just wrote for its
widget (`ios/HeadroomMobile/WatchBridge.swift`); the watch writes it into its
own app group (`watch/HeadroomWatch/WatchLink.swift`), where the extension
reads it exactly as the home-screen widgets read the phone's. No second wire
format, and nothing on the watch ever fetches.

Two WatchConnectivity channels, because neither is enough alone:

| Channel | Budget | Delivers |
|---|---|---|
| `updateApplicationContext` | unbudgeted | only while the watch app runs |
| `transferCurrentComplicationUserInfo` | ~50/day | wakes the extension with the app closed |

So the second one is rationed: it is spent only when the attention level
changes, a source appears or leaves, or one moves five points or more. Below
that the ring redraws at the same angle to the eye and the transfer would be
wasted.

## Complications

| Kind | Families | Shows |
|---|---|---|
| **Coding quotas** | `accessoryCircular`, `accessoryCorner` | The combined dial — one band per source (see [`rings.md`](rings.md)) |
| **Overall burndown** | `accessoryRectangular`, `accessoryInline` | The week, redrawn for the wrist |

The rectangular one is a deliberate reduction of the Mac card, not a shrunk
copy. At roughly 160×72 points the legend, the percent gutter and the weekday
labels all stop working. What replaces them:

- **No text.** The chart takes the whole tile. It used to carry a headline —
  the percent, the source, **Empty Thu** / **Resets Thu** — but that is the
  same sentence the inline and corner families already say, and it cost a fifth
  of the height that makes the lines readable.
- **History ghosts stay.** The spent windows behind the live curve are the same
  faint sawtooth the phone, Mac and widget draw — already on the snapshot the
  phone forwards — so the week still reads as a week.
- **The binding source's line is the only thick one.** The rest keep full
  colour as context — same as the board — and separate by weight, not by fading
  out.
- **The axis goes, the rhythm stays.** Day boundaries keep their rules and lose
  their labels; the scale keeps its lines and loses "100%".

Words come back for exactly one case: nothing to draw. A blank tile and a flat
week look identical, so an empty chart says **Nothing yet** — or **Open
Headroom on iPhone** when the watch has never heard from the phone, which is
the one of the two the wearer can act on.

### Colour on the face

A complication renders `.accented` by default: the system discards the view's
own colours and repaints it in whatever tint the watch face is wearing. That is
opt-out, not mandatory. **`.widgetAccentable(false)` keeps a subtree's real
colours**, which is how the rings and the burndown lines wear the same brand
hues here that they wear in the app, on the widgets and on the Mac.

Both complications apply it to their drawn content. Anything left outside it —
the corner's curved `widgetLabel`, the `accessoryInline` string — is system
text the face styles regardless, and is meant to be.

### Why the watch draws in Display P3

The board and the Apple surfaces paint identical numbers: `COL_CLAUDE` in
`firmware/src/main.cpp` and `claudeRGB` in `Shared/HeadroomPalette.swift` are
both `217, 119, 87`. They do not look identical, and the gap is colour
management, not the palette.

`Color(red:green:blue:)` is sRGB, and the system renders it accurately —
meaning inside sRGB's gamut. An ESP32 panel has no colour management at all:
the RGB565 value drives the OLED subpixels directly, against primaries much
wider than sRGB. Same coordinates, wider primaries, visibly more saturation.

So `watch/Shared/WatchPalette.swift` reads the same triples as **Display P3**
coordinates, which is close to what the unmanaged panel does, and every watch
surface uses `provider.watchTint` instead of `provider.tint`. The numbers are
never duplicated — `HeadroomPalette` keeps the triples and both spellings are
derived from them.

This is watch-only on purpose. The Mac would overshoot on any external sRGB
monitor, and it is not trying to match a board across the room.

Two things it does not fix: RGB565 quantisation, which costs the board up to 7
of 255 per channel (`(r & 0xF8, g & 0xFC, b >> 3)`), and the fact that a 30pt
patch of colour simply reads less saturated than a 448×368 one.

## Freshness

The extension builds twelve timeline entries twenty minutes apart and asks for
a reload after four hours. Nothing in the payload changes between phone pushes,
but the now rule and the snapshot's age do, and stepping them locally keeps the
face honest without spending the day's complication budget by lunchtime. Real
freshness comes from the phone's pushes — both the foreground refresh and the
background one (`MobileBackgroundRefresh`), which used to update only the
home-screen widget and leave the wrist on the last open of the phone app.

A watch that has never heard from the phone shows **Open Headroom on iPhone**.

## Building

The watch targets need the watchOS platform installed in Xcode
(**Settings → Components**). Without it, `xcodebuild` refuses every watchOS
destination *and* the iPhone scheme, which now embeds the watch app.

```bash
xcodebuild build -project macos/Headroom.xcodeproj -scheme HeadroomWatch -destination 'generic/platform=watchOS Simulator'
```
