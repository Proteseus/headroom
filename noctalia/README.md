# Headroom for noctalia-shell

This integration runs Headroom's local Python host as a systemd user service
and supplies two independent noctalia-shell widgets:

- **Headroom** displays the three focused AI quota pools.
- **Coolify** displays live queued/building deployments and keeps the latest
  failed deployment per application visible for 24 hours, or until a newer
  successful deployment replaces it. Click its compact state rail to expand
  application names, deployment states, and ages directly in the bar.

## Requirements

- Arch Linux with `python` and `quickshell` installed
- noctalia-shell in `~/.config/quickshell/noctalia-shell`
- A Headroom checkout at `~/.local/share/headroom`

The host has no Python package dependencies. On Linux it skips its optional
macOS `/usr/bin/dns-sd` Bonjour advertiser automatically.

## Install the host

Clone or copy this repository to the path used by the service:

```bash
git clone <headroom-repository-url> ~/.local/share/headroom
mkdir -p ~/.config/systemd/user
cp ~/.local/share/headroom/scripts/headroom.service ~/.config/systemd/user/headroom.service
systemctl --user daemon-reload
systemctl --user enable --now headroom.service
```

Confirm that the local endpoint responds:

```bash
curl http://localhost:8737/usage
systemctl --user status headroom.service
```

Logs are available with:

```bash
journalctl --user -u headroom.service -f
```

If the checkout lives elsewhere, edit both paths in
`~/.config/systemd/user/headroom.service`, then run `systemctl --user
daemon-reload` and restart the service.

## Install the widgets

For the canonical linked setup, including the Coolify service environment and
bar-widget registration, follow [PORTABLE_SETUP.md](PORTABLE_SETUP.md). The
summary below covers the original Headroom widget; Coolify follows the same
registry pattern documented there.

Copy the widget and settings component into noctalia-shell:

```bash
cp ~/.local/share/headroom/noctalia/Modules/Bar/Widgets/Headroom.qml \
  ~/.config/quickshell/noctalia-shell/Modules/Bar/Widgets/Headroom.qml
cp ~/.local/share/headroom/noctalia/Modules/Bar/WidgetSettings/HeadroomSettings.qml \
  ~/.config/quickshell/noctalia-shell/Modules/Panels/Settings/Bar/WidgetSettings/HeadroomSettings.qml
```

Then edit
`~/.config/quickshell/noctalia-shell/Services/UI/BarWidgetRegistry.qml` and add
Headroom in four places alongside the existing widgets:

1. Add `"Headroom": headroomComponent` to `widgets`.
2. Add `"Headroom": "WidgetSettings/HeadroomSettings.qml"` to
   `widgetSettingsMap`.
3. Add this entry to `widgetMetadata`:

   ```qml
   "Headroom": {
     "allowUserSettings": true,
     "hostUrl": "http://localhost:8737",
     "pollInterval": 30
   }
   ```

4. Add the component definition:

   ```qml
   property Component headroomComponent: Component {
     Headroom {}
   }
   ```

Restart noctalia-shell, open its bar settings, and add **Headroom**, **Coolify**,
or both to the desired bar section. Each widget has an independent host URL and
poll interval. Polling switches to 5 seconds while a widget is hovered. On a
horizontal bar, left-click **Coolify** to expand or collapse its deployment
details; right-click either widget to open its settings.

Local `localhost` access does not require a Headroom token. If the host URL is
changed to another machine, that host's `/usage` authentication policy applies;
this widget intentionally has no field for storing or transmitting a token.

## Update or remove

After updating the Headroom checkout, repeat the two widget copy commands and
restart noctalia-shell. To stop and disable the host:

```bash
systemctl --user disable --now headroom.service
```

Remove the two copied QML files and the four registry additions to uninstall
the bar integration.
