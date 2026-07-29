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
copy. At roughly 160×72 points, rendered `.accented` — where the system
flattens everything to one tint and colour cannot carry identity at all — the
legend, the percent gutter, the weekday labels, and the per-source hues all
stop working. What replaces them:

- One source is **named in words** above the chart: whichever runs dry first,
  with how much is left and **Empty Thu** / **Resets Thu**. That is the
  question a glance is asking, and text answers it where an 8pt legend cannot.
- **Its line is the accented one, and the only thick one.** The rest stay in
  the base tone as context — the shape of the week, not a key to decode.
- **The axis goes, the rhythm stays.** Day boundaries keep their rules and lose
  their labels; the scale keeps its lines and loses "100%".

Splitting a view across the two tones needs two stacked `Canvas` layers —
`.widgetAccentable()` groups views and cannot reach inside one. Both build
their geometry from the same `BurndownGeometry`, so the layers register.

## Freshness

The extension builds twelve timeline entries twenty minutes apart and asks for
a reload after four hours. Nothing in the payload changes between phone pushes,
but the now rule and the snapshot's age do, and stepping them locally keeps the
face honest without spending the day's complication budget by lunchtime. Real
freshness comes from the phone's pushes.

A watch that has never heard from the phone shows **Open Headroom on iPhone**.

## Building

The watch targets need the watchOS platform installed in Xcode
(**Settings → Components**). Without it, `xcodebuild` refuses every watchOS
destination *and* the iPhone scheme, which now embeds the watch app.

```bash
xcodebuild build -project macos/Headroom.xcodeproj -scheme HeadroomWatch -destination 'generic/platform=watchOS Simulator'
```
