# Host reference

Config files under `~/.headroom/`, HTTP endpoints, and how the menu bar notices
a stale embedded host. For first-run setup see [setup.md](setup.md).

## Personal config (`~/.headroom/config.json`)

| Key | Purpose |
|---|---|
| `timezone` | Local day boundary for burn + timestamps |
| `dev_root` | Where git / GitHub repo discovery walks |
| `git_authors` | `git log --author` patterns (empty = all authors) |
| `vercel_team_slugs` | Preferred Vercel team(s); empty → CLI current team |
| `github_org_prefix` | Owner filter for discovered Actions repos — one `"owner/"` or a list; empty = every repo found |
| `github_always_repos` | Always-watched `owner/name` list |
| `github_max_discovered` | Cap on auto-discovered repos |
| `plausible_sites` | Optional domain filter / fallback when the key cannot list sites |
| `plausible_host` | Cloud or self-hosted base URL (default `https://plausible.io`) |
| `plausible_range` | Primary window: `day`, `24h` (default), `7d`, or `30d` |
| `posthog_projects` | Optional project-id filter / fallback when the key cannot list projects |
| `posthog_host` | US / EU / self-hosted base URL (default `https://us.posthog.com`) |
| `posthog_range` | Primary window: `day`, `24h` (default), `7d`, or `30d` |
| `sentry_org` | Sentry organization slug (token is Keychain-only) |
| `datadog_site` | Datadog site host, e.g. `datadoghq.com` / `datadoghq.eu` |
| `axiom_host` | Axiom API base (default `https://api.axiom.co`; EU `https://api.eu.axiom.co`) |
| `axiom_org_id` | Optional org id header for Axiom PATs |
| `gemini_oauth_client_id` / `_secret` | Only if Gemini refreshes fail: public client constants the host normally reads from the installed `gemini` CLI |
| `auth_token` | Override the generated **host token** |
| `require_auth` | `false` opens `/usage` to the whole network (default `true`) |
| `mobile_permissions` | iOS grants: `read`, `refresh`, `sources`, `servers` |

## Source preferences (`~/.headroom/sources.json`)

Seeded from local detection on first run, then written by Settings. Three keys:

- `enabled` — `{id: bool}`
- `order` — pinned provider ids; the first three enabled become `focus`
- `integrations_order` — pinned Integrations catalog ids (code and deploys,
  balances, services, local servers/builds). Activity lays out the subset that
  paints blocks in this order. Claude Code / Codex live under Settings →
  Agents, not this list. Legacy `services_order` is still read once as a
  migrate seed.
- `accents` — `{id: "#RRGGBB"}` for rows you recolored; delete an entry to
  restore the shipped colour

## Extra accounts (`~/.headroom/accounts.json`)

Written by **Settings → Providers → Add account**; editable by hand and picked
up on the next host start. Each entry is a label plus a credential location —
never a token.

```json
{
  "claude": [{ "slug": "work", "label": "Work", "root": "~/.claude-work" }],
  "codex":  [{ "slug": "alt",  "label": "Alt",  "root": "~/.codex-alt" }]
}
```

`root` is the config folder for Claude / Codex / Gemini and the `state.vscdb`
itself for Cursor / Windsurf. The row shows up as `claude:work` everywhere a
source id does — `sources[]`, `providers[]`, `focus`, burndown, samples.

## Endpoints

Everything below is loopback-open and token-gated off-box. Trust classes:
[trust.md](trust.md). Contract rules for `/usage`: [contract.md](contract.md).

| Path | Notes |
|---|---|
| `GET /usage` | Full flat JSON for the menu bar (~40KB) |
| `GET /usage?view=device` | ~5KB projection the ESP32 polls |
| `GET /health` | Host `version` + `build`, uptime, compact source status, cache age, last board check-in |
| `GET /setup` | Detected credentials + enabled map + order / focus / accents (first-run sheet) |
| `GET /github/watch` | Actions watch settings + resolved repos (loopback) |
| `POST /github/watch` | Replace those watch settings (loopback) |
| `GET /accounts` | Extra logins per provider (loopback) |
| `POST /accounts` | Add or drop an extra login, then restart (loopback) |
| `GET /mobile/permissions` | Four effective permissions for the paired iOS app |
| `POST /sync/refresh` | Force-refresh (LAN OK — ESP32 long-press) |
| `POST /sources` | Toggle sources, pin order, and/or recolor rows. Loopback or paired iOS with `sources` scope |
| `POST /supabase/refresh` | Force Supabase poll (loopback) |
| `POST /plausible/refresh` | Force Plausible poll (loopback) |
| `POST /posthog/refresh` | Force PostHog poll (loopback) |
| `POST /local/stop` | Stop server (loopback or paired iOS with `servers` scope) |
| `POST /attention/ack` | Clear the current warning everywhere until its reasons change |
| `POST /mobile/permissions` | Replace iOS grants (loopback / Mac settings only) |

The served document is rebuilt once per poll tick and cached as bytes.
`attention.level` is `ok` | `warn` | `critical` — acknowledgement is stored by
fingerprint so clearing on one surface clears the same warning everywhere.

## Host version

launchd keeps whatever host it was given running across app updates, so the
menu bar can end up reading a build it never shipped. `/health` reports
`version` (`host/VERSION`) and `build` (fingerprint of shipped `.py` files).
The app offers **Update host** in the popover when the two disagree.

macOS / iOS marketing versions track `host/VERSION`; `CFBundleVersion` is the
git commit count. Cut releases with `./scripts/cut-release.sh` — see
[releasing.md](releasing.md).
