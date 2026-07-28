# Releasing Headroom

Marketing version lives in [`host/VERSION`](../host/VERSION) (semver, hand-bumped).
Apple build numbers are `git rev-list --count HEAD` via [`scripts/version-env.sh`](../scripts/version-env.sh).

Tag releases as `v` + that version (e.g. `1.0.0` → `v1.0.0`). The release
workflow refuses a tag that does not match `host/VERSION`.

Public download URLs (macOS Releases + iOS TestFlight) live in
[`install-links.md`](install-links.md) and are embedded in GitHub Release notes.

## Checklist (first release)

1. **GitHub Actions secrets** — run
   [`scripts/setup-release-secrets.sh`](../scripts/setup-release-secrets.sh)
   (or set the table below in the repo Settings UI). Without these, tags still
   publish an **ad-hoc** `Headroom-macOS.zip` (Gatekeeper warns).
2. **App Store Connect app** — `com.centaur-labs.headroom` (id `6795549853`).
   Set GitHub secret `ASC_APP_ID` to that id. Optional: `ASC_TESTFLIGHT_GROUP`
   (default `Internal`).
3. **Smoke upload** — locally:
   ```bash
   export ASC_APP_ID=6795549853
   export APPLE_API_KEY_PATH=~/.appstoreconnect/private_keys/AuthKey_YAX564736L.p8
   export APPLE_API_KEY_ID=YAX564736L
   export APPLE_API_ISSUER_ID=3cfd203a-f83c-4f1b-8895-2f31c9c02a26
   ./scripts/build-ios.sh --upload
   ```
4. **Public TestFlight link** — ASC → TestFlight → Public Link → paste into
   [`install-links.md`](install-links.md) → commit.
5. **Cut the tag** — `./scripts/cut-release.sh`

## Cut a release

```bash
# bump host/VERSION if needed, commit, then:
./scripts/cut-release.sh
# or: git tag v1.0.0 && git push origin v1.0.0
```

What the [Release workflow](../.github/workflows/release.yml) does on a `v*` tag:

| Step | Behavior |
|---|---|
| macOS zip | Always. Notarized when signing + ASC secrets exist; else ad-hoc. |
| GitHub Release | Attaches `Headroom-macOS.zip` + notes (incl. TestFlight URL if set). |
| TestFlight | Soft-attempt: `asc publish testflight` → Internal group when ASC secrets + `ASC_APP_ID` exist. |
| IPA asset | Attached to the same Release when the upload ran. |

Manual **Actions → Release → Run workflow** can force notarize / TestFlight
without a tag (artifacts only — no GitHub Release).

Local notarized build (same secrets as env vars):

```bash
export HEADROOM_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export APPLE_API_KEY_PATH=~/.appstoreconnect/private_keys/AuthKey_XXXXXX.p8
export APPLE_API_KEY_ID=XXXXXX
export APPLE_API_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
./scripts/build-app.sh --release --notarize
```

## One-time Apple setup

### 1. Developer ID (macOS notarization)

1. [Apple Developer](https://developer.apple.com/account/resources/certificates/list) →
   create **Developer ID Application** (needs a CSR from Keychain Access).
2. Install the cert in Keychain, then export as `.p12`.
3. Base64 for GitHub (or let `setup-release-secrets.sh` do it):

```bash
base64 -i DeveloperID.p12 | pbcopy
```

### 2. App Store Connect API key (notarize + TestFlight)

1. [Users and Access → Integrations → Team Key](https://appstoreconnect.apple.com/access/integrations/api)
2. Create a key with **Developer** (or Admin) access; download the `.p8` once.
3. Note Key ID + Issuer ID.

### 3. GitHub Actions secrets

| Secret | Value |
|---|---|
| `MACOS_CERTIFICATE_P12` | base64 of the Developer ID `.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | password used when exporting the `.p12` |
| `KEYCHAIN_PASSWORD` | any random string (CI temp keychain) |
| `APPLE_API_KEY` | raw `.p8` PEM contents |
| `APPLE_API_KEY_ID` | Key ID |
| `APPLE_API_ISSUER_ID` | Issuer ID |
| `ASC_APP_ID` | App Store Connect app id (`6795549853`) |
| `ASC_TESTFLIGHT_GROUP` | Optional; default `Internal` |

Helper (needs a `gh` token that can write Actions secrets):

```bash
./scripts/setup-release-secrets.sh \
  --p12 ~/Desktop/DeveloperID.p12 \
  --p12-password '…' \
  --api-key ~/.appstoreconnect/private_keys/AuthKey_XXXX.p8 \
  --api-key-id XXXX \
  --api-issuer-id xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

### 4. TestFlight public link

1. Create an iOS app in App Store Connect with bundle id `com.centaur-labs.headroom`.
2. Upload a build (`./scripts/build-ios.sh --upload` or a tagged Release).
3. Enable TestFlight; add yourself as an internal tester.
4. Create a **Public Link** group and copy `https://testflight.apple.com/join/…`
   into [`install-links.md`](install-links.md).
5. Ensure an **Apple Distribution** certificate exists for the team (Xcode →
   Settings → Accounts → Manage Certificates).

Missing ASC setup never blocks the macOS zip on a tag — the iOS job soft-skips.

## App Store listing

Canonical copy lives in [`appstore.md`](appstore.md) (name, subtitle, description,
keywords, promo, what’s new, review notes, screenshot plan). Privacy policy:
[`privacy.md`](privacy.md).

Push metadata (same parser as TinySuite):

```bash
python3 ../tiny/scripts/push-metadata.py \
  --bundle-id com.centaur-labs.headroom \
  --metadata-file docs/appstore.md \
  --dry-run
```

## Version map

| Surface | Marketing | Build |
|---|---|---|
| Host `/health` | `host/VERSION` | content fingerprint of shipped `.py` |
| Headroom | same | commit count |
| HeadroomMobile + widget | same | commit count |
| ESP32 firmware | n/a | local `firmware/.build_number` (per flash machine) |
