# Linux Parity Completion Audit

This checklist is evidence, not a roadmap. A row can be marked complete only after the named artifact
exists and the observable verification succeeds against the current release build.

## Core and Providers

| Requirement | Artifact | Required evidence | Status |
|---|---|---|---|
| Complete metric vocabulary | `UsageModels.swift` | Codable round-trip tests for every metric kind | Full 102-test suite passed |
| Claude parity and multi-account | Claude Linux provider files | Fixture tests plus discovered config-directory accounts | Fixture and registry tests passed |
| Codex parity and reset credits | Codex Linux provider files | Fixture tests, token rotation, claim and reset-credit tests | Fixture and registry tests passed |
| Cursor parity | Cursor Linux files | Credential, live meter and fallback fixture tests | Fixture and registry tests passed |
| Copilot parity | Copilot Linux files | Editor/GH/Secret Service precedence and billing tests | Fixture and registry tests passed |
| Antigravity parity | Antigravity Linux files, direct GIO Secret Service and Flatpak permission | Summary, OAuth, identity, current `agy` keyring and file-fallback tests | Fixtures plus real keyring-only server refresh passed |
| OpenCode parity | OpenCode Linux files | Multi-database spend/quota/history tests | Fixture and registry tests passed |
| OpenRouter parity | OpenRouter Linux files | API key, endpoint and metric fixture tests | Fixture and registry tests passed |
| Grok parity | Grok Linux files | Auth, live quota and local-spend fixture tests | Fixture and registry tests passed |
| Z.ai parity | Z.ai Linux files | API key precedence and mapping tests | Fixture and registry tests passed |
| Devin parity | Devin Linux files | XDG auth, quota/balance and fallback tests | Fixture and registry tests passed |
| Pi usage fold-in | Pi Linux files | Bounded scanning, deduplication and pricing tests | Fold-in and scanner tests passed |
| Provider registry | Linux registry and repository | Every discovered provider/account refreshed with four-operation bound | Five registry tests passed |
| Last-good preservation | Linux repository | Failure after success retains metrics and marks stale error | Deterministic stale test passed |

## Usage Intelligence

| Requirement | Artifact | Required evidence | Status |
|---|---|---|---|
| Claude and Codex local scanners | Linux scanner files | macOS-equivalent JSONL fixtures | Implemented, dedicated tests passed |
| Bundled pricing | Linux pricing resource target | Alias/supplement/catalog resolution tests | Implemented, dedicated tests passed |
| Spend periods | Linux aggregation service | Today, Yesterday and 30 Days boundary tests | Implemented, dedicated tests passed |
| Daily history | Linux history model | 31 finite points maximum per series | Implemented, dedicated tests passed |
| Account separation | snapshot instance IDs and aggregation | Same provider with two accounts remains distinct | Registry and fixture tests passed |

## Linux Services

| Requirement | Artifact | Required evidence | Status |
|---|---|---|---|
| Secret Service | Linux credential backend | fake transport tests plus real `secret-tool` round-trip | Passed in isolated DBus/Xvfb session |
| XDG settings | Linux settings store | permissions, migration, ordering and appearance tests | Settings and full suite passed |
| Periodic refresh | desktop service | one retained timer and no overlapping refreshes | Implemented, deterministic test passed |
| Notifications | Freedesktop adapter | fake DBus test plus `notify-send`/portal observation | Passed in isolated DBus/Xvfb session |
| Autostart | systemd/XDG adapters and metadata | enable/disable/status QA | Real systemd enable/disable passed |
| Global shortcut | XDG portal adapter | fake DBus test plus portal capability QA | Activation/session cleanup test passed; host portal unavailable |
| Tray | StatusNotifierItem adapter | registration, activation and shutdown QA | Registration/activation test passed; host watcher unavailable |
| Local HTTP API | Linux API executable/service | live loopback curl against release build | Native GET/404/signals and packaged `/v1/usage` passed |
| CLI parity | Linux CLI executable | help, success, JSON and bad-input QA | Native edge paths plus packaged help/JSON passed |
| Export/import/share | `UsageExportService.swift` and UI action | JSON round-trip, CSV contract, default opener | Core tests and AT-SPI JSON action passed |
| Update delivery | `LinuxUpdateDelivery.swift`, Flatpak | no privileged self-update; package-manager guidance | Full Flatpak build passed |
| Analytics preference | settings and HTTP analytics adapter | opt-in/out persistence with no PII | Five privacy tests and UI wiring passed |

## GNOME Experience

| Requirement | Artifact | Required evidence | Status |
|---|---|---|---|
| Adaptive four-view shell | GNOME UI sources | 360, 720 and 1024 pixel screenshots | Wide and 360px narrow captures passed |
| Provider identity | shared upstream SVG marks and `ProviderIcon.swift` | all-provider 24/28px light/dark gallery, fallback and package checks | 10 marks normalized; two independent reviewers passed |
| Native overview | overview renderer | populated spend/quota visual QA | Populated spend, filter, quotas and health captured |
| Provider details | provider detail renderer | every metric kind, link and account visible | Expanded account metrics and links captured |
| History charts | chart renderer | bounded Cairo chart plus accessible description | Light and high-contrast charts captured |
| Native settings | settings renderer | persisted controls exercise real services | Appearance, refresh, visibility/order, startup, API and privacy wired |
| Onboarding and errors | status/onboarding renderer | missing auth, expired auth, partial failure QA | Fixture and live missing-auth states exercised |
| Accessibility | widget semantics | keyboard traversal and accessibility inspection | AT-SPI smoke passed: 187 nodes, 13 controls, 4 named progress bars |
| Theme support | semantic libadwaita styling | light, dark and high-contrast screenshots | Light, dark and high-contrast captures passed |

## Efficiency

| Requirement | Artifact | Required evidence | Status |
|---|---|---|---|
| Bounded HTTP bodies | `BoundedHTTPTransport.swift` | declared and chunked overflow tests | Boundary and full suite passed |
| Repository single-flight | `UsageRepository.swift` | 50 concurrent callers produce one pass | Concurrency test passed |
| Bounded snapshot cache | `SnapshotCache.swift` | size/provider/metric limit tests | Size/provider tests passed |
| Managed GTK lifetimes | controller and callback bridge | close during refresh and 100 reopen cycles | Signal/callback tests pass; settled stress measurement passed |
| Persistent widget updates | dashboard controller | unchanged cards not rebuilt | Persistent views/cards implemented |
| Measured memory | profiler and measurements document | release PSS, 100 refresh and close/reopen bounds | 87,431→87,607 KiB switches; 67,591→67,591 KiB refreshes |

## Distribution and Documentation

| Requirement | Artifact | Required evidence | Status |
|---|---|---|---|
| Flatpak | Linux manifest, offline sources and provider SVG bundle | `flatpak-builder` plus packaged execution | Full build; packaged GUI/CLI/API and symbolic marks passed |
| Desktop metadata | `linux/*.desktop`, metainfo and icons | desktop/AppStream validation | Validators passed |
| systemd user service | `linux/` unit | install, enable, start and stop QA | Verify and enable/disable passed |
| Build documentation | Linux README | clean-machine command review | Complete with native and Flatpak commands |
| HIG design documentation | `DESIGN.md`, `linux-parity.md` | visual reviewers pass against sources | Corrected visual evidence passed |

## Final Commands

All commands must run after concurrent implementation has settled:

```sh
swift test
swift build -c release --product OpenUsageGNOME
swift build -c release --product openusage
swift build -c release --product openusage-api
desktop-file-validate linux/io.github.minpeter.OpenUsage.desktop
appstreamcli validate --no-net linux/io.github.minpeter.OpenUsage.metainfo.xml
flatpak-builder --force-clean --disable-rofiles-fuse .flatpak-build linux/io.github.minpeter.OpenUsage.yml
./scripts/profile-linux-memory.sh .build/release/OpenUsageGNOME
```

Manual QA must additionally exercise the live app, CLI, loopback API, tray activation, portal shortcut,
notifications, autostart, export/import, responsive themes, keyboard navigation, and a real provider
credential path. Proxy signals such as a green build or manifest validation do not replace those checks.
