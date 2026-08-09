#!/usr/bin/env bash
set -euo pipefail

app=${1:-.build/release/OpenUsageGNOME}
root=$(mktemp -d)
cache="$root/cache/openusage"
mkdir -p "$cache"

cleanup() {
  rm -rf "$root"
}
trap cleanup EXIT

xvfb-run -a bash -euo pipefail -c '
  app=$1
  root=$2
  cache=$3
  inotifywait --quiet --event close_write --timeout 60 "$cache" >"$root/cache-event" &
  watcher=$!
  HOME="$root/home" \
    XDG_CONFIG_HOME="$root/config" \
    XDG_CACHE_HOME="$root/cache" \
    GSK_RENDERER=cairo \
    "$app" &
  pid=$!

  finish() {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  }
  trap finish EXIT

  xdotool search --sync --onlyvisible --name OpenUsage >/dev/null
  printf "visible\n"
  awk "/^(Rss|Pss|Private_Dirty):/" "/proc/$pid/smaps_rollup"

  wait "$watcher"
  printf "refreshed\n"
  awk "/^(Rss|Pss|Private_Dirty):/" "/proc/$pid/smaps_rollup"
' profile-linux-memory "$app" "$root" "$cache"
