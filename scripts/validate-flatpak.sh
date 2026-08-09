#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

manifest=linux/io.github.minpeter.OpenUsage.yml
metainfo=linux/io.github.minpeter.OpenUsage.metainfo.xml
desktop=linux/io.github.minpeter.OpenUsage.desktop
unit=linux/io.github.minpeter.OpenUsage.service

python3 - "$manifest" <<'PY'
import sys
try:
    import yaml
except ImportError as error:
    raise SystemExit("PyYAML is required to validate the Flatpak YAML manifest") from error

with open(sys.argv[1], encoding="utf-8") as source:
    manifest = yaml.safe_load(source)
required = {"app-id", "runtime", "runtime-version", "sdk", "command", "modules"}
missing = sorted(required - manifest.keys())
if missing:
    raise SystemExit(f"manifest is missing required keys: {', '.join(missing)}")
if manifest["app-id"] != "io.github.minpeter.OpenUsage":
    raise SystemExit("manifest app-id does not match the desktop metadata")
PY

desktop-file-validate "$desktop"
appstreamcli validate --no-net --pedantic "$metainfo"
systemd-analyze --user verify "$unit"

if command -v flatpak-builder >/dev/null 2>&1; then
    flatpak-builder --show-manifest "$manifest" >/dev/null
else
    printf '%s\n' "SKIP: flatpak-builder is not installed; manifest expansion and a sandboxed build were not run." >&2
fi

python3 - "$manifest" linux/Package.resolved Package.resolved <<'PY'
import json
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as source:
    manifest = yaml.safe_load(source)
with open(sys.argv[2], encoding="utf-8") as source:
    linux_lock = json.load(source)
with open(sys.argv[3], encoding="utf-8") as source:
    macos_lock = json.load(source)

git_sources = [source for module in manifest["modules"] for source in module["sources"] if source["type"] == "git"]
pins = {pin["identity"]: pin for pin in linux_lock["pins"]}
revision = pins["swift-adwaita"]["state"]["revision"]
if revision != git_sources[0]["commit"]:
    raise SystemExit("swift-adwaita manifest commit and Linux lockfile revision differ")
expected_macos = {"keyboardshortcuts", "posthog-ios", "sparkle"}
actual_macos = {pin["identity"] for pin in macos_lock["pins"]}
if actual_macos != expected_macos:
    raise SystemExit("root Package.resolved no longer contains the macOS dependency set")
PY
