# Fork factory

This repository is a fork of [robinebers/openusage](https://github.com/robinebers/openusage).

- `linux` is the public product branch (the GTK4 Linux port) and the repository default. Scheduled GitHub Actions live here.
- `upstream` and `main` are fast-forward mirrors of upstream `main`. They carry no product commits and no factory workflow file.

Weekdays at 09:00 KST, [`.github/workflows/upstream-sync.yml`](../.github/workflows/upstream-sync.yml) fast-forwards those mirrors, then opens a `sync/YYYY-MM-DD` merge PR into `linux`. Actions do not merge that PR.
