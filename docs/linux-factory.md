# Fork factory

This repository is a fork of [robinebers/openusage](https://github.com/robinebers/openusage).

- `linux` is the public product branch (the GTK4 Linux port) and the repository default. Scheduled GitHub Actions live here.
- `upstream` and `main` are fast-forward mirrors of upstream `main`. They carry no product commits and no factory workflow file.

Weekdays at 09:00 KST, [`.github/workflows/upstream-sync.yml`](../.github/workflows/upstream-sync.yml) fast-forwards those mirrors, then opens a `sync/YYYY-MM-DD` merge PR into `linux`. That weekday cron is the default path. Actions do not merge that PR.

To start the same workflow on demand, send a repository dispatch of type `upstream-sync` (ordinary contents write; no Actions `workflow` scope):

```sh
gh api --method POST /repos/minpeter/openusage/dispatches \
  -f event_type=upstream-sync
```

Do not use `gh workflow run` or the `workflow_dispatch` API from an agent token. Those calls need Actions write (or a classic token with the `workflow` scope) and return HTTP 403 for typical GitHub App and fine-grained tokens. The Actions UI Run workflow button still works for humans.
