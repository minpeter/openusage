# Linux and Flatpak development

OpenUsage GNOME requires Swift 6.1 or newer, GTK 4, and libadwaita 1.6 or newer.

On Ubuntu, a host build can be run with:

```sh
sudo apt install swiftlang libadwaita-1-dev xvfb
cp linux/Package.resolved Package.resolved
swift test
swift run OpenUsageGNOME
# Restore the macOS lockfile before committing packaging work.
git restore Package.resolved
```

The separate `linux/Package.resolved` is intentional. The root lockfile remains the macOS lockfile;
SwiftPM evaluates the platform-conditional dependency graph and otherwise rewrites that file when
resolution runs on Linux.

The app reads Claude Code credentials from `~/.claude/.credentials.json` and Codex credentials from
`${XDG_CONFIG_HOME:-~/.config}/codex/auth.json` or `~/.codex/auth.json`. In Flatpak those locations
are mounted read-only. Application cache and settings remain in Flatpak's private XDG directories.

## Build the Flatpak

The manifest uses the current GNOME 50 runtime and SDK plus the matching
`org.freedesktop.Sdk.Extension.swift6` SDK extension. `swift-adwaita` is pinned by both Git revision
and `linux/Package.resolved`. flatpak-builder downloads that revision during its source-fetch phase,
then SwiftPM resolves it through a local file mirror in the network-isolated build sandbox. The app
is always compiled from the checkout; no local or downloaded OpenUsage binary is used.

Install the build tools and runtimes, validate the repository files, and build. On Ubuntu, install
repository validators with `sudo apt install flatpak-builder appstream desktop-file-utils python3-yaml`.
Then run:

```sh
flatpak remote-add --user --if-not-exists flathub \
  https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --user flathub \
  org.gnome.Platform//50 org.gnome.Sdk//50 \
  org.freedesktop.Sdk.Extension.swift6//25.08
./scripts/validate-flatpak.sh
flatpak-builder --user --force-clean --install-deps-from=flathub \
  --repo=.flatpak-repo .flatpak-build linux/io.github.minpeter.OpenUsage.yml
flatpak build-bundle .flatpak-repo OpenUsage.flatpak \
  io.github.minpeter.OpenUsage stable
```

For a stricter network-isolation check, download all declared sources first and then build with the
network unavailable. flatpak-builder does not grant module builds network access; the second command
uses only its source cache and the installed SDK:

```sh
flatpak-builder --download-only --force-clean .flatpak-build \
  linux/io.github.minpeter.OpenUsage.yml
flatpak-builder --disable-download --force-clean --repo=.flatpak-repo \
  .flatpak-build linux/io.github.minpeter.OpenUsage.yml
```

Install and run the locally built application with:

```sh
flatpak install --user --reinstall .flatpak-repo io.github.minpeter.OpenUsage
flatpak run io.github.minpeter.OpenUsage
```

## systemd user service

Flatpak does not export arbitrary systemd units to the host. The bundle carries a validated unit as
documentation and for extraction, but enabling it is an explicit host-side operation:

```sh
mkdir -p ~/.config/systemd/user
flatpak run --command=cat io.github.minpeter.OpenUsage \
  /app/share/openusage/systemd/user/io.github.minpeter.OpenUsage.service \
  > ~/.config/systemd/user/io.github.minpeter.OpenUsage.service
systemctl --user daemon-reload
systemctl --user enable --now io.github.minpeter.OpenUsage.service
systemctl --user status io.github.minpeter.OpenUsage.service
```

Disable and remove it with:

```sh
systemctl --user disable --now io.github.minpeter.OpenUsage.service
rm ~/.config/systemd/user/io.github.minpeter.OpenUsage.service
systemctl --user daemon-reload
```

## Traditional local installation

```sh
cp linux/Package.resolved Package.resolved
swift build -c release --product OpenUsageGNOME
install -Dm755 .build/release/OpenUsageGNOME ~/.local/bin/OpenUsageGNOME
install -Dm644 linux/io.github.minpeter.OpenUsage.desktop \
  ~/.local/share/applications/io.github.minpeter.OpenUsage.desktop
install -Dm644 linux/io.github.minpeter.OpenUsage.metainfo.xml \
  ~/.local/share/metainfo/io.github.minpeter.OpenUsage.metainfo.xml
install -Dm644 linux/io.github.minpeter.OpenUsage.svg \
  ~/.local/share/icons/hicolor/scalable/apps/io.github.minpeter.OpenUsage.svg
git restore Package.resolved
```
