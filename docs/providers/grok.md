# Grok

Tracks Grok Build credit usage using the login from the Grok CLI.

## What it tracks

| Metric | Meaning |
|---|---|
| Weekly | The shared weekly pool's usage percent (the limit Grok's unified billing enforces), with the weekly reset countdown |
| Usage Limit Resets | On-demand reset tokens from grok.com Settings → Usage ("Reset Available"), shown as a count (e.g. `2 available`). Zero is shown when the dedicated call succeeds with no tokens. Hover the value on Mac for each token's expiry; Linux uses the same expiry detail path as Codex resets. This is not the weekly pool countdown. |
| Extra Usage | Pay-as-you-go cap as a status (e.g. `2500 cap` or `Disabled`) |
| Today / Yesterday / Last 30 Days | Local cost and tokens from completed Grok CLI sessions |

When Grok reports your subscription tier, OpenUsage shows it beside the provider name.

The weekly shared pool is the limit Grok enforces for unified-billing accounts (the old monthly credits meter is legacy and no longer shown). Accounts that haven't been migrated to unified billing have no weekly pool, so the Weekly tile reads "No data" there.

## Where credentials come from

Sign in once with the Grok CLI (`grok login`); OpenUsage reads the same `~/.grok/auth.json`. Access tokens refresh automatically before expiry, and rotated tokens are written back to the file.

## The spend tiles

Today / Yesterday / Last 30 Days are computed **locally** from completed Grok CLI sessions under `~/.grok/sessions/` (or `$GROK_HOME/sessions/`). Subagent usage is counted through its parent session, so parallel tasks do not inflate the totals. OpenUsage uses the cost Grok recorded for each completed turn when available; older turns without a recorded cost are estimated using the shared [model pricing](../pricing.md). Days follow your Mac's local time zone, and each period shows cost and tokens together (`$4.08 · 1.2M tokens`). These amounts are separate from the credits reported by Grok's billing API, and no session data leaves your Mac. A period with no completed usage reads "No data" rather than `$0.00 · 0 tokens`.

## Troubleshooting

- **"Session expired" / auth errors** — run `grok login` again, then refresh.
- **Weekly shows "No data"** — your account still reports a monthly (non-weekly) period, meaning it hasn't been migrated to Grok's unified weekly billing yet.
- **Spend tiles show "No data"** — they need completed Grok CLI turns under `~/.grok/sessions/`; a turn that is still running has not been recorded yet. Finish a Grok CLI session, then refresh.

## Under the hood

`GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` for the weekly pool and pay-as-you-go cap — the exact call the Grok CLI itself makes — and `…/v1/settings` for the plan name; token refresh via `auth.x.ai`. A 401/403 triggers one token refresh and retry.

Usage Limit Resets come from a best-effort `POST https://grok.com/prod_mc_billing.ConsumerUiSvc/GetRemainingResets` (grpc-web, empty request) using the same Grok CLI OIDC bearer as billing — the RPC behind grok.com Settings → Usage. Each token carries `token_id`, `validity_start`, and `validity_end`. A failed or unparseable call omits the row and does not fail Weekly / Pay as you go. A successful empty list reads `0 available`. The weekly `currentPeriod.end` countdown is never reused as a fake reset-rights count. Extra Usage Credits / Auto Top Up stay on their own rows.
