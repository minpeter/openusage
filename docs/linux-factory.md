# Fork factory

This repository is a fork of [robinebers/openusage](https://github.com/robinebers/openusage).

- `linux` is the public product branch (the GTK4 Linux port) and the repository default. Scheduled GitHub Actions live here.
- `upstream` and `main` are fast-forward mirrors of upstream `main`. They carry no product commits and no factory workflow file.

Weekdays at 09:00 KST, [`.github/workflows/upstream-sync.yml`](../.github/workflows/upstream-sync.yml) fast-forwards those mirrors, then opens a `sync/YYYY-MM-DD` merge PR into `linux`. That weekday cron is the default path. The mirror stays fast-forward only (no force-push). Actions do not merge that PR.

`secrets.GITHUB_TOKEN` cannot create or update files under `.github/workflows/` (GitHub App `workflows` permission). When upstream adds or changes a workflow, the FF push is rejected and integrate is skipped.

Set a repository Actions secret named `FACTORY_PAT` so the mirror can land those commits:

- Classic PAT: `repo` + `workflow`
- Fine-grained PAT: Contents write + Workflows write

The job uses `FACTORY_PAT` when that secret is present, and falls back to `GITHUB_TOKEN` only when it is unset. If a run hits the GitHub App workflows-permission refusal, it fails with that `FACTORY_PAT` / workflow-file reason instead of a bare exit.

To start the same workflow on demand, send a repository dispatch of type `upstream-sync` (ordinary contents write; no Actions `workflow` scope):

```sh
gh api --method POST /repos/minpeter/openusage/dispatches \
  -f event_type=upstream-sync
```

Do not use `gh workflow run` or the `workflow_dispatch` API from an agent token. Those calls need Actions write (or a classic token with the `workflow` scope) and return HTTP 403 for typical GitHub App and fine-grained tokens. The Actions UI Run workflow button still works for humans.
