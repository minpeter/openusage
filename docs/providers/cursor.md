# Cursor

Tracks your Cursor plan usage using the login from the Cursor app.

## What it tracks

| Metric | Meaning |
|---|---|
| Credits | Credit balance left from grants and prepaid account balance |
| Cursor Models | Monthly first-party pool from the Spending tab (Cursor Grok and Composer). Used percent and monthly reset. This is not Auto-mode-only and not Grok Bot weekly |
| Other Models | Monthly third-party pool from the Spending tab. Used percent and monthly reset. Pro / Pro+ / Ultra include this pool — a real 0% is shown when unused. Start, or a response that omits the pool entirely, shows “No data” — OpenUsage does not invent 0% for an absent pool |
| Total Usage | Team dollar pool or request-based Enterprise included-request count vs. cap. Not shown on the default individual Spending card (that card is Cursor Models + Other Models) |
| Requests | Optional copy of the included request count vs. cap for custom layouts |
| Grok Bot Weekly | Cursor dashboard Grok Bot weekly pool (used percent and weekly reset). This is not grok.com / Grok CLI Weekly, not the monthly Cursor Models pool, and not Cursor CSV spend for `cursor-grok-…` model slugs. Accounts without the pool, or responses that omit it, show “No data” — OpenUsage does not invent 0% |
| Extra Usage | On-demand spend; user-scoped when available, otherwise the team aggregate; shown as a meter when Cursor returns a limit. Separate from the two monthly pools and from Grok Bot weekly |

When Cursor reports your plan name, OpenUsage shows it beside the provider name.

## Where credentials come from

Just be signed into the Cursor app. OpenUsage reads Cursor's local state database (and its keychain entries) for the session tokens; refreshed tokens are persisted back. Nothing extra to install or configure.

## Spend history

Today, Yesterday, Last 30 Days, and Usage Trend come from Cursor's usage export. OpenUsage uses the exported token counts and shared model pricing to estimate the cost locally. Cursor's export may occasionally arrive late, so the newest figures can lag behind current activity. OpenUsage leaves isolated malformed rows out instead of silently counting broken values as zero. A failed download, invalid export schema, or broken CSV structure leaves spend history unavailable for that refresh. Each failure is recorded in the diagnostic log without including the exported usage data.

## Troubleshooting

- **"Not logged in" / token errors** — open Cursor and make sure you're signed in, then refresh.
- **Some metrics missing** — Cursor omits fields depending on plan type; missing metrics simply show "No data".
- **Optional lookup failed** — plan, credit-grant, prepaid-balance, Grok Bot weekly, and request-fallback failures stay nonfatal when primary usage is available. OpenUsage records fixed, credential-free reasons in the diagnostic log.
- **Grok Bot Weekly shows “No data”** — the Cursor dashboard Grok Bot weekly pool is missing from this account or Cursor omitted it. That is not grok.com / Grok CLI Weekly.

## Under the hood

Connect RPC on `api2.cursor.sh` (dashboard usage via `GetCurrentPeriodUsage`, plus the Cursor-owned Grok Bot weekly pool via `GetSandUsageStatus`), combined REST at `cursor.com/api/usage-summary` (the Spending bars) and `cursor.com/api/usage` for Enterprise/team request fallback, Stripe balance at `cursor.com/api/auth/stripe`, and the usage-events CSV export at `cursor.com/api/dashboard/export-usage-events-csv`. Cursor Models reads `totalPercentUsed` (or a newer dedicated field), not leftover `autoPercentUsed`. Other Models reads `apiPercentUsed` / usage-summary / a newer dedicated field, and shows unused 0% when the plan includes the pool. The Grok Bot weekly meter is not on the monthly usage snapshot and is not the grok.com / Grok CLI weekly pool; OpenUsage reads it with the same Cursor session token already used for dashboard usage. The Enterprise fallback combines the included request allowance with the two Spending percentages and user-scoped on-demand spend; neither REST response is treated as the whole account snapshot by itself. The primary dashboard usage request refreshes the token and retries once after a 401/403; optional endpoint failures (including a missing Grok Bot weekly field) stay nonfatal when the other fallback response is usable and are recorded in the diagnostic log. Per-day spend imputation uses exported token counts priced through the shared [model pricing](../pricing.md); Cursor-native models (`auto`, `composer-*`, …) come from its supplement layer, which maintainers sync from [Cursor models & pricing](https://cursor.com/docs/models-and-pricing.md).
