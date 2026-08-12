# Portable Linux + Noctalia setup

This checkout is the canonical source for the Linux host and Noctalia UI.
The live installation should contain symlinks back to this repository, so a
pull updates both without copying source files around.

The examples use an explicit checkout path. Change it for the new machine:

```bash
HEADROOM_REPO=/home/deb/projects/private_projects/headroom
```

## Install the host helper

OpenCode Go quota collection uses the locked Node helper under `tools/`:

```bash
npm ci --prefix "$HEADROOM_REPO/tools"
```

`tools/node_modules/` is intentionally untracked. `package.json` and
`package-lock.json` are tracked so the dependency can be reproduced.

## Link the host and service

Create the live parent directory and link its `host` entry to the checkout:

```bash
mkdir -p ~/.local/share/headroom
ln -s "$HEADROOM_REPO/host" ~/.local/share/headroom/host
```

If `~/.local/share/headroom/host` is already a real directory, move it aside
once before creating the link:

```bash
mv ~/.local/share/headroom/host ~/.local/share/headroom/host.before-repo-link
ln -s "$HEADROOM_REPO/host" ~/.local/share/headroom/host
```

Link and enable the systemd user service:

```bash
mkdir -p ~/.config/systemd/user
ln -sfn "$HEADROOM_REPO/scripts/headroom.service" ~/.config/systemd/user/headroom.service
systemctl --user daemon-reload
systemctl --user enable --now headroom.service
```

### Connect Coolify

Enable API access in Coolify, then create a token with the read-only `read`
permission. Copy the environment template and paste the token locally; this
file is outside the repository and must remain private:

```bash
mkdir -p ~/.config/headroom
install -m 600 "$HEADROOM_REPO/noctalia/environment.example" \
  ~/.config/headroom/environment
${EDITOR:-nano} ~/.config/headroom/environment
systemctl --user daemon-reload
systemctl --user restart headroom.service
```

Enable the source once for an existing Headroom installation. Fresh installs
detect the configured environment automatically:

```bash
curl -X POST http://127.0.0.1:8737/sources \
  -H 'Content-Type: application/json' \
  --data '{"enabled":{"coolify":true}}'
```

The token never enters `/usage`, QML settings, or logs. The widget reads the
normalized Coolify block from the loopback Headroom host.

Verify it with:

```bash
curl http://127.0.0.1:8737/usage
systemctl --user status headroom.service
```

## Link the Noctalia components

The integration has seven source files. Keep the different repository and
Noctalia settings paths exactly as shown:

```bash
NOCTALIA=~/.config/quickshell/noctalia-shell

mkdir -p "$NOCTALIA/Modules/Bar/Widgets"
mkdir -p "$NOCTALIA/Modules/Panels/Headroom"
mkdir -p "$NOCTALIA/Modules/Panels/Settings/Bar/WidgetSettings"

ln -sfn "$HEADROOM_REPO/noctalia/Modules/Bar/Widgets/Headroom.qml" \
  "$NOCTALIA/Modules/Bar/Widgets/Headroom.qml"
ln -sfn "$HEADROOM_REPO/noctalia/Modules/Bar/Widgets/HeadroomRing.qml" \
  "$NOCTALIA/Modules/Bar/Widgets/HeadroomRing.qml"
ln -sfn "$HEADROOM_REPO/noctalia/Modules/Panels/Headroom/HeadroomPanel.qml" \
  "$NOCTALIA/Modules/Panels/Headroom/HeadroomPanel.qml"
ln -sfn "$HEADROOM_REPO/noctalia/Modules/Panels/Headroom/HeadroomPanelContent.qml" \
  "$NOCTALIA/Modules/Panels/Headroom/HeadroomPanelContent.qml"
ln -sfn "$HEADROOM_REPO/noctalia/Modules/Bar/WidgetSettings/HeadroomSettings.qml" \
  "$NOCTALIA/Modules/Panels/Settings/Bar/WidgetSettings/HeadroomSettings.qml"
ln -sfn "$HEADROOM_REPO/noctalia/Modules/Bar/Widgets/Coolify.qml" \
  "$NOCTALIA/Modules/Bar/Widgets/Coolify.qml"
ln -sfn "$HEADROOM_REPO/noctalia/Modules/Bar/WidgetSettings/CoolifySettings.qml" \
  "$NOCTALIA/Modules/Panels/Settings/Bar/WidgetSettings/CoolifySettings.qml"
```

Noctalia's `Services/UI/BarWidgetRegistry.qml` still needs its local Headroom
registry entries. It belongs to Noctalia and is deliberately not replaced by
a repository symlink, because replacing that shared file would discard local
or upstream widget registrations.

Register `Coolify` beside `Headroom` in the same four places:

```qml
"Coolify": coolifyComponent,

"Coolify": "WidgetSettings/CoolifySettings.qml",

"Coolify": {
  "allowUserSettings": true,
  "hostUrl": "http://localhost:8737",
  "pollInterval": 15
},

property Component coolifyComponent: Component {
  Coolify {}
}
```

No panel or `MainScreen.qml` changes are needed. The individual deployment
states live directly in the bar; hover the widget for application, state, and
age details.

## OpenCode Go credentials

OpenCode Go's browser session is machine-local and must never be committed.
Sign into `opencode.ai` in the browser used on that machine, open the
subscribed workspace's `/go` page, then configure the helper:

```bash
"$HEADROOM_REPO/tools/node_modules/.bin/opencode-quota" init
```

The resulting workspace ID and `auth` cookie belong in:

```text
~/.config/opencode/opencode-quota/opencode-go.json
```

Keep that file mode `0600`. If quotas disappear while the subscription is
active, first check that the helper points to the browser profile and workspace
that owns the subscription. API credentials in OpenCode's `auth.json` are not
the same as the web dashboard session used for Go quota windows.

## Updating

After the links exist, update only the checkout and dependencies:

```bash
git -C "$HEADROOM_REPO" pull --ff-only
npm ci --prefix "$HEADROOM_REPO/tools"
systemctl --user restart headroom.service
```

No QML copy step is needed; Noctalia reads the repository files through the
links.
