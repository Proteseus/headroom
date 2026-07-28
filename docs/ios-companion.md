# Headroom for iPhone

The iOS companion is a second application target in `macos/HeadroomBar.xcodeproj`.
It reads the same registry-driven `/usage` document as the Mac menu bar app and
ESP32 display. No cloud service or second database is involved.

## MVP

- Manual pairing with the Mac's `.local` hostname or LAN IP and the existing
  `~/.headroom/token`.
- Token stored in the iOS Keychain.
- Provider quota rings driven by `providers[].pools`.
- Attention summary.
- Pull-to-refresh, including the existing LAN-safe `POST /sync/refresh`.
- iPhone and iPad layouts from one target.

The mobile target is intentionally read-only beyond sync refresh. Source
configuration and process control remain Mac-only because `/sources` and
`/local/stop` reject non-loopback callers.

## Build

```bash
cd macos
xcodegen generate
xcodebuild -project HeadroomBar.xcodeproj -scheme HeadroomMobile \
  -sdk iphonesimulator -configuration Debug build
```

For a physical phone, select `HeadroomMobile`, choose your Development Team,
and run on a device on the same network as the Mac. On first use, allow local
network access.

Use a connection such as:

```text
http://your-mac.local:8737/usage
```

Copy the token from the Mac:

```bash
cat ~/.headroom/token
```

## Next increments

1. Advertise the host with Bonjour and discover it automatically on iOS.
2. Show a QR pairing sheet in the Mac app carrying host, port, and a short-lived
   pairing secret.
3. Add widgets backed by an App Group cache.
4. Add activity and burndown detail screens.
5. Package the iOS archive alongside the signed/notarized Mac release. iOS apps
   cannot be embedded inside a macOS `.app`; "side by side" means two targets
   and two platform artifacts in the same Xcode project/release.
