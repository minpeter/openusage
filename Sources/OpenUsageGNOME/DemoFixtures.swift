import Foundation
import OpenUsageLinuxCore

/// Deterministic populated snapshots used for visual verification when
/// `OPENUSAGE_DEMO_DATA=1` is set. Loaded instead of live repository data so
/// screenshots exercise every metric shape, state, and link without
/// credentials. Values depend only on the current time, never on randomness.
enum DemoFixtures {
    static let referenceNow = Date(timeIntervalSince1970: 1_786_320_000)

    static let environmentFlag = "OPENUSAGE_DEMO_DATA"
    static let pageFlag = "OPENUSAGE_DEMO_PAGE"
    static let sizeFlag = "OPENUSAGE_DEMO_SIZE"
    static let expandFlag = "OPENUSAGE_DEMO_EXPAND"
    static let allProvidersFlag = "OPENUSAGE_DEMO_ALL_PROVIDERS"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment[environmentFlag] == "1"
    }

    /// Optional initial page override for capturing a specific view.
    static var requestedPage: String? {
        ProcessInfo.processInfo.environment[pageFlag]?.nilIfEmpty
    }

    /// When set, provider rows render pre-expanded for metric-shape shots.
    static var expandProviders: Bool {
        ProcessInfo.processInfo.environment[expandFlag] == "1"
    }

    static var showAllProviders: Bool {
        ProcessInfo.processInfo.environment[allProvidersFlag] == "1"
    }

    /// Optional "<width>x<height>" window size override for adaptive shots.
    static var requestedSize: (width: Int, height: Int)? {
        guard let raw = ProcessInfo.processInfo.environment[sizeFlag]?.nilIfEmpty else {
            return nil
        }
        let parts = raw.split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    static func snapshots(now: Date = referenceNow) -> [ProviderUsageSnapshot] {
        let primary = [
            claude(now: now),
            codex(now: now),
            openRouter(now: now),
        ]
        guard showAllProviders else { return primary }
        return primary + [
            iconSnapshot("antigravity", "Antigravity", now: now),
            iconSnapshot("copilot", "GitHub Copilot", now: now),
            iconSnapshot("cursor", "Cursor", now: now),
            iconSnapshot("devin", "Devin", now: now),
            iconSnapshot("grok", "Grok", now: now),
            iconSnapshot("opencode", "OpenCode", now: now),
            iconSnapshot("zai", "Z.ai", now: now),
        ]
    }

    private static func iconSnapshot(
        _ providerID: String,
        _ displayName: String,
        now: Date
    ) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            providerID: providerID,
            displayName: displayName,
            plan: nil,
            metrics: [],
            refreshedAt: now
        )
    }

    private static func claude(now: Date) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            providerID: "claude",
            displayName: "Claude",
            accountLabel: "Claude Code - work@example.com",
            plan: "Max 5x",
            metrics: [
                UsageMetric(
                    kind: .progress, label: "Current Session", used: 62, limit: 100,
                    resetsAt: now.addingTimeInterval(2_400),
                    detail: "Five-hour rolling window"
                ),
                UsageMetric(
                    kind: .progress, label: "Weekly All Models", used: 38, limit: 100,
                    resetsAt: now.addingTimeInterval(196_800)
                ),
                UsageMetric(
                    kind: .values, label: "Today", used: 4.21,
                    values: [
                        UsageValue(label: "", value: 4.21, unit: .dollars),
                        UsageValue(label: "tokens", value: 1_284_500, unit: .tokens),
                    ]
                ),
                UsageMetric(
                    kind: .chart, label: "Usage Trend",
                    used: 24_912_000,
                    points: chartPoints(now: now, seed: 3)
                ),
            ],
            links: [
                ProviderLink(label: "Usage Dashboard", url: "https://claude.ai/settings/usage"),
                ProviderLink(label: "Console", url: "https://console.anthropic.com"),
            ],
            refreshedAt: now.addingTimeInterval(-95)
        )
    }

    private static func codex(now: Date) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            providerID: "codex",
            displayName: "Codex",
            accountLabel: "dev@example.com",
            plan: "Plus",
            metrics: [
                UsageMetric(
                    kind: .progress, label: "Primary Rate Limit", used: 81, limit: 100,
                    resetsAt: now.addingTimeInterval(10_200)
                ),
                UsageMetric(
                    kind: .progress, label: "Weekly Rate Limit", used: 47, limit: 100,
                    resetsAt: now.addingTimeInterval(302_400)
                ),
                UsageMetric(
                    kind: .values, label: "Credits", used: 18.50,
                    detail: "Flexible usage credits",
                    values: [UsageValue(label: "credits", value: 37, unit: .credits)],
                    expiriesAt: [now.addingTimeInterval(1_209_600)]
                ),
                UsageMetric(kind: .badge, label: "Status", used: 0, text: "Operational"),
                UsageMetric(
                    kind: .chart, label: "Usage Trend",
                    used: 9_410_000,
                    points: chartPoints(now: now, seed: 7)
                ),
            ],
            links: [
                ProviderLink(label: "Codex Usage", url: "https://chatgpt.com/codex/settings/usage"),
            ],
            refreshedAt: now.addingTimeInterval(-95)
        )
    }

    /// Stale-last-good: the refresh failed but the previous values stay
    /// visible with an annotation and a retry action.
    private static func openRouter(now: Date) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            providerID: "openrouter",
            displayName: "OpenRouter",
            accountLabel: "sk-or-…-personal",
            plan: "Pay As You Go",
            metrics: [
                UsageMetric(
                    kind: .progress, label: "Daily Limit", used: 44, limit: 100,
                    resetsAt: now.addingTimeInterval(57_600)
                ),
                UsageMetric(
                    kind: .value, label: "Credits Remaining", used: 12.75,
                    detail: "Across all keys"
                ),
                UsageMetric(
                    kind: .text, label: "Note", used: 0,
                    text: "Live usage rate limited - data may be stale"
                ),
            ],
            links: [
                ProviderLink(label: "OpenRouter Activity", url: "https://openrouter.ai/activity"),
            ],
            refreshedAt: now.addingTimeInterval(-4_700),
            errorMessage: "OpenRouter usage request failed with HTTP 401."
        )
    }

    /// 31 daily points from a fixed arithmetic pattern per provider seed.
    private static func chartPoints(now: Date, seed: Int) -> [UsagePoint] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        return (0...30).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else {
                return nil
            }
            let day = 30 - offset
            let wave = (day * 7 + seed * 13) % 11
            let weekend = calendar.component(.weekday, from: date)
            let base = Double((wave + 2) * seed) * 96_000
            let scaled = weekend == 1 || weekend == 7 ? base * 0.35 : base
            return UsagePoint(date: date, value: scaled)
        }
    }
}
