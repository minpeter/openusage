#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

app=${1:-.build/release/OpenUsageGNOME}
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/home" "$root/config" "$root/cache" "$root/receipt"

xvfb-run -a dbus-run-session -- bash -euo pipefail -c '
  root=$1
  app=$2
  export HOME="$root/home"
  export XDG_CONFIG_HOME="$root/config"
  export XDG_CACHE_HOME="$root/cache"
  export GSK_RENDERER=cairo
  export OPENUSAGE_DEMO_DATA=1
  export OPENUSAGE_PERFORMANCE_RECEIPT="$root/receipt/performance.json"

  "$app" >"$root/app.log" 2>&1 &
  pid=$!
  cleanup() {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  }
  trap cleanup EXIT

  xdotool search --sync --onlyvisible --name OpenUsage >/dev/null
  gapplication action io.github.minpeter.OpenUsage run-performance-probe
  test -s "$OPENUSAGE_PERFORMANCE_RECEIPT"

  python3 - "$OPENUSAGE_PERFORMANCE_RECEIPT" <<"PY"
import json
import math
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    report = json.load(source)

durations = sorted(report["updateDurationsMilliseconds"])
if len(durations) != 100:
    raise SystemExit(f"expected 100 GTK update samples, got {len(durations)}")
p95 = durations[math.ceil(len(durations) * 0.95) - 1]
idle = report["idlePSSBytes"]
final = report["finalPSSBytes"]
growth = max(0, final - idle)
if idle > 128 * 1024 * 1024:
    raise SystemExit(f"idle PSS exceeds 128 MiB: {idle}")
if growth > 2 * 1024 * 1024:
    raise SystemExit(f"settled PSS growth exceeds 2 MiB: {growth}")
if p95 >= 16:
    raise SystemExit(f"GTK update p95 exceeds 16 ms: {p95}")
print(
    f"PERFORMANCE_PASS samples=100 idle={idle} "
    f"growth={growth} p95_ms={p95}"
)
PY
' verify-linux-performance "$root" "$app"
