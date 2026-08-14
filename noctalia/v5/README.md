# Headroom plugin for Noctalia v5

This is the native Noctalia v5 version of Headroom's two bar widgets. It uses
Noctalia's TOML manifest and sandboxed Luau plugin API; it does not copy or load
the v4 QML components.

The plugin provides:

- `centaur-labs/headroom:headroom` — focused AI quota sources, exact remaining
  percentages, attention status, and an attached quota details panel.
- `centaur-labs/headroom:coolify` — queued, running, and recently failed
  Coolify deployments. Click it on a horizontal bar to expand deployment names,
  states, and ages in place.

The v5 declarative API does not expose a canvas. The Headroom bar entry therefore
uses a colored donut glyph and exact percentage for each provider instead of the
v4 widget's hand-drawn concentric rings. The details panel preserves the quota
breakdown as native progress rows.

## Requirements

- Noctalia v5 with plugin API 3 or newer
- The Headroom host running at `http://localhost:8737` (the default)
- Noctalia online mode enabled for plugin HTTP requests

The host setup is unchanged. Follow the host and optional Coolify sections in
[../PORTABLE_SETUP.md](../PORTABLE_SETUP.md), then confirm:

```bash
curl http://localhost:8737/usage
```

## Install from this checkout

Add `noctalia/v5` as a local plugin source, enable the plugin, and then add its
two widgets from Noctalia's bar editor:

```bash
HEADROOM_REPO=/home/deb/projects/private_projects/headroom
noctalia msg plugins source add headroom path "$HEADROOM_REPO/noctalia/v5"
noctalia msg plugins enable centaur-labs/headroom
```

Open **Settings → Bar**, choose **Add widget**, and select **Headroom** or
**Coolify**. Each placement has its own host URL and poll interval. Middle-click
a widget to open its settings using Noctalia's standard widget gesture;
right-click is also supported by the plugin. Hovering temporarily polls every
five seconds.

The path source is read directly and Luau edits hot-reload. Manifest edits are
picked up on the next config reload. No registry patches, QML symlinks, or
`MainScreen.qml` changes are needed.

## Validate changes

Noctalia includes an offline plugin-author linter. Run it from the Headroom
checkout without starting the shell:

```bash
noctalia plugins lint noctalia/v5/headroom
```

The plugin targets API 3 deliberately. It only uses baseline v5 capabilities:
declarative bar/panel UI, asynchronous HTTP, JSON decoding, per-widget settings,
shared plugin state, tooltips, and pointer callbacks.

## Remove

Remove the widgets from the bar, then disable the plugin and delete its source:

```bash
noctalia msg plugins disable centaur-labs/headroom
noctalia msg plugins source remove headroom
```
