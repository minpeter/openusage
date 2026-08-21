# Linux Functional Parity

This document defines user-facing parity between the macOS app and the GTK 4/libadwaita Linux app.
Platform-specific implementations may differ, but every row must have the same observable outcome.

## Providers

| Provider | Credentials | Live usage | Local usage/cost | Multi-account | Detail links |
|---|---|---:|---:|---:|---:|
| Antigravity | local database/files | Required | Required | Required when discovered | Required |
| Claude | Claude Code files, Secret Service | Required | Required | Required | Required |
| Codex | Codex auth files, Secret Service | Required | Required | Required when discovered | Required |
| Copilot | GitHub credentials | Required | When available | Required when discovered | Required |
| Cursor | Cursor files/database | Required | Required | Required when discovered | Required |
| Devin | browser/session files | Required | When available | Required when discovered | Required |
| Grok | browser/session files | Required | When available | Required when discovered | Required |
| OpenCode | OpenCode files/database | Required | Required | Required when discovered | Required |
| OpenRouter | API key, Secret Service | Required | Required | Required | Required |
| Pi | Pi files | Required | Required | Required when discovered | Required |
| Z.ai | API key/session files | Required | When available | Required | Required |

Every provider must preserve the macOS metric vocabulary, plan label, account identity, reset timestamps,
typed error category, stale-last-good behavior, widget descriptors, and safe external links.

## Usage Intelligence

- Today, Yesterday, and 30 Days spend views match the macOS date boundaries.
- Model pricing uses the same bundled snapshots, supplements, aliases, and resolution rules.
- Local log scanners produce the same token and cost totals from the same fixtures.
- Provider and account totals remain separately addressable.
- Trend data is bounded to 31 daily points per provider series.
- Codex reset-credit count and expiry information is visible when available.

## Application Behavior

| macOS behavior | Linux equivalent | Acceptance |
|---|---|---|
| Menu-bar popover | StatusNotifierItem plus application window | Tray activation presents the existing window |
| Global shortcut | XDG GlobalShortcuts portal | Configured shortcut presents the window |
| Launch at login | systemd user unit and XDG autostart fallback | Survives logout/login and remains user-controlled |
| Keychain | Freedesktop Secret Service | API keys never enter settings, logs, or snapshot files |
| UserDefaults/settings | Versioned XDG JSON settings | Ordering, visibility, appearance, refresh, proxy, logging, and panel display settings persist |
| Local API | Loopback HTTP server with the same JSON contract | Existing API consumers parse equivalent data |
| CLI | Linux executable sharing the same core | Happy, error, JSON, and help behavior match |
| Notifications | Freedesktop notification portal | Threshold and provider errors are actionable |
| Sparkle | Flatpak or package-manager updates | No application-managed privileged updater |
| iCloud sync | Export/import plus optional user-selected sync directory | Settings and snapshots round-trip without Apple services |
| Share screenshot | PNG image clipboard with inline copy feedback | Matches the macOS copy action using GTK's native `GdkClipboard` texture support |
| Hide during screen share | Hidden: no GNOME/Wayland capture-exclusion API | No disabled stub row; public compositor APIs are re-evaluated when available |

## GNOME Experience

- Two top-level views: Overview and Providers. Settings opens as a dialog, not a tab.
- The view switcher moves to the bottom edge when the header cannot contain it.
- The full feature set remains available from 360 logical pixels wide through desktop widths.
- Overview, Providers, and Settings share one card per provider account. Catalog or file-fallback
  duplicates do not appear twice, and a provider present in Settings also appears in the other views.
- Overview and provider content uses clamped boxed lists rather than floating macOS-style panels.
- Quota window copy is human-readable (`1 week`, `5 hours`). Raw millisecond periods never appear.
- Header bars contain only window-level actions; row actions live in rows or detail pages.
- Destructive, warning, success, and error states use semantic styling plus text and icons.
- Keyboard focus, accessible labels/descriptions, system font scaling, dark mode, and high contrast work.
- The StatusNotifierItem label, when a watcher is present, defaults to the most
  urgent healthy quota. Settings does not advertise Pin-to-Panel or other
  panel-only controls on GNOME, where there is no menu-bar extra surface.
- Animations respect reduced-motion preferences and never gate data availability.

## Efficiency Budgets

- Idle PSS: no more than 128 MiB under the reproducible Cairo/Xvfb release gate after both GTK
  views have been warmed. Native compositor measurements are recorded separately because driver and
  portal PSS varies by desktop.
- Refresh growth: no more than 10 MiB over settled idle for all enabled providers.
- One repository-wide refresh pass, at most four provider operations, and two connections per host.
- Auth and usage responses: 512 KiB maximum; snapshot cache: 1 MiB maximum.
- Snapshot cache: at most 32 providers and 64 metrics per provider.
- Charts: at most 31 points and four series per provider.
- GTK updates: below 16 ms p95 without rebuilding unaffected cards.
- Close/reopen and 100 refresh cycles settle within 2 MiB of the post-warm-up PSS.

## Verification Gate

Parity is complete only when provider fixtures, pricing and scanner fixtures, settings migrations, CLI,
loopback API, tray, shortcut, autostart, notifications, Flatpak permissions, accessibility, responsive
screenshots, and memory-growth checks all pass in one release build.

## Design Sources

- GNOME HIG adaptive design: https://developer.gnome.org/hig/guidelines/adaptive.html
- GNOME HIG header bars: https://developer.gnome.org/hig/patterns/containers/header-bars.html
- GNOME HIG view switchers: https://developer.gnome.org/hig/patterns/nav/view-switchers.html
- GTK accessibility: https://docs.gtk.org/gtk4/section-accessibility.html
- XDG portals: https://flatpak.github.io/xdg-desktop-portal/docs/
- Flatpak desktop integration: https://docs.flatpak.org/en/latest/desktop-integration.html
