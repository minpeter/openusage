# Linux Memory Measurements

Measurements use the release `OpenUsageGNOME` binary, deterministic populated snapshots, an Xvfb display,
an isolated D-Bus session, and the Cairo GTK renderer. PSS is read from `/proc/<pid>/smaps_rollup`.

## Results

| Scenario | Before | After | Growth |
|---|---:|---:|---:|
| Populated window after first presentation | 80,395 KiB PSS | - | - |
| First 100 view switches | 75,368 KiB | 88,593 KiB | 13,225 KiB lazy GTK/Cairo initialization |
| 100 switches after one warm-up cycle | 84,570 KiB | 88,508 KiB | 3,938 KiB additional caches |
| 100 switches after full warm-up | 87,431 KiB | 87,607 KiB | 176 KiB settled growth |
| 100 identical refreshes after warm-up | 67,591 KiB | 67,591 KiB | 0 KiB |

The historical measurements above predate the full parity Settings, Total Spend, model breakdown,
sharing, and provider interaction surfaces. On the completed parity build, the reproducible
Cairo/Xvfb release probe records 116-120 MiB PSS on the reference host. Native compositor runs record
181-199 MiB because graphics-driver and portal mappings vary by desktop. The enforced portable idle
budget is therefore 128 MiB for Cairo/Xvfb; native-compositor idle PSS remains an observation.

The relevant leak signal is the fully warmed measurement. The process grows by 176 KiB across another
100 navigation changes, below the 2 MiB settled-growth budget.
The larger first-cycle increase is one-time GTK view realization, font, icon, and Cairo cache population.
The refresh path compares display content before updating widgets; 100 identical refreshes produced no
PSS growth after warm-up.

## Reproduction

```sh
swift build -c release --product OpenUsageGNOME
xvfb-run -a dbus-run-session -- bash -euc '
  OPENUSAGE_DEMO_DATA=1 GSK_RENDERER=cairo .build/release/OpenUsageGNOME &
  pid=$!
  trap "kill $pid 2>/dev/null || true" EXIT
  window=$(xdotool search --sync --onlyvisible --name OpenUsage | head -n 1)
  for cycle in $(seq 1 25); do
    for key in 1 2 3 4; do xdotool key --window "$window" ctrl+$key; done
  done
  awk "/^Pss:/ {print \"before\", \$2}" "/proc/$pid/smaps_rollup"
  for cycle in $(seq 1 25); do
    for key in 1 2 3 4; do xdotool key --window "$window" ctrl+$key; done
  done
  awk "/^Pss:/ {print \"after\", \$2}" "/proc/$pid/smaps_rollup"
'
```
