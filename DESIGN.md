# OpenUsage GNOME Design

## 0. Research Log

- Source contract: `assets/screenshot.jpg` and the existing SwiftUI dashboard.
- GNOME surface: GTK 4 with libadwaita, using native cards, progress bars, header bars, and status pages.
- Scope: preserve the provider-first information hierarchy rather than reproducing macOS panel chrome.

## 1. Product Intent

OpenUsage GNOME is an adaptive desktop dashboard for checking every supported AI account, quota, token,
and cost signal without opening provider websites. The first screen must answer three questions
immediately: which account is connected, how much of each limit is used, and when each limit resets.

## 2. Visual Language

- Follow the active libadwaita light or dark appearance.
- Use native Adwaita surfaces and typography; do not imitate macOS translucency.
- Keep the original hierarchy: spend summary, provider identity, plan, quota rows, reset time, refresh status.
- Use the user's GNOME system accent for healthy usage, amber for warnings, and red for provider failures.

## 3. Layout

- Default window: 720 by 720 logical pixels, resizable down to 360 by 294.
- `AdwHeaderBar`: application identity, adaptive view switcher, and window-level refresh action.
- Four views: Overview, Providers, History, Settings.
- `AdwViewSwitcher` is centered in the header at wide widths and moves to `AdwViewSwitcherBar` at narrow widths.
- Vertical scrolling content uses 18-pixel outer margins and 12-pixel section spacing.
- Content is clamped to 720 logical pixels to preserve readable density on wide windows.
- Providers are ordered by the user's persisted order, then account label.
- Each quota row contains label, percentage or value, progress bar, and reset copy.

## 4. Components

- Provider identity: the upstream vector mark rendered as a monochrome symbolic icon; initials are the
  fallback only when a provider has no bundled mark.
- Provider card: symbolic provider icon, display name, plan badge, state message.
- Progress metric: title, trailing used percentage, progress bar, optional reset time.
- Value metric: title, primary value, optional detail.
- Error state: visible inline message with a retry action in the header.
- Empty state: actionable login instruction from the provider adapter.
- Overview: spend summary, time filter, provider health summary, and the most urgent quota windows.
- Providers: boxed provider/account rows with disclosure into complete metric details.
- History: bounded daily charts and a provider/account legend.
- Settings: native preferences groups for providers, ordering, refresh, appearance, startup, shortcuts, API, and privacy.
- Panel indicator setting: a native combo row defaults to the most urgent quota and can switch to icon-only.

## 5. Interaction

- Refresh is explicit and also runs once on launch.
- A single five-minute periodic refresh runs while the application service is active.
- Disable the refresh button while a request is active.
- Preserve the last successful values while a refresh is in progress.
- Preserve the last successful values and show a stale/error annotation when one provider fails.
- Keyboard focus order follows header controls, then provider cards from top to bottom.
- Tray activation, portal shortcut activation, and a second application launch present the existing window.

## 6. Accessibility

- Every progress bar exposes its label and percentage.
- Never rely on color alone; warning and error copy remains visible.
- Respect system font scaling and high-contrast themes.
- Keep interactive targets at least 40 logical pixels tall.
- Every chart exposes the same points through an accessible tabular description.
- Animations follow the desktop reduced-motion setting and are never required to understand state.

## 7. Responsive Behavior

- At 360 pixels, metric labels and values wrap instead of clipping and all four views remain available.
- At narrow widths, provider details use a single navigation stack rather than side-by-side panes.
- Above 900 pixels, provider navigation may use an adaptive split view while content remains clamped.
- Scrolling belongs to the content area; the header remains fixed.

## 8. Efficiency Contract

- Keep one persistent root and provider-card tree; update values in place rather than rebuilding unaffected widgets.
- Keep one refresh task, four provider operations, and two connections per host at maximum.
- Cap authenticated HTTP bodies at 512 KiB and snapshot cache files at 1 MiB.
- Keep 31 daily chart points and four series per provider.
- Use one Cairo drawing area per chart, never one widget per point.
- Cancel refresh, timers, signals, and pending GTK callbacks when the application service stops.

## 9. Platform Equivalents

- Secret Service replaces Keychain.
- StatusNotifierItem replaces the menu-bar item where the desktop supports indicators.
- XDG GlobalShortcuts replaces the macOS global shortcut.
- Freedesktop notifications replace UserNotifications.
- systemd user services and XDG autostart replace launch-at-login.
- Flatpak or the distribution package manager replaces Sparkle.
- Export/import and a user-selected sync directory replace iCloud.
