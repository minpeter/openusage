import Foundation
import OpenUsageLinuxCore
import Testing
@testable import OpenUsageGNOME

@Suite("GNOME values copy")
struct GNOMEValuesCopyTests {
    private let now = Date(timeIntervalSince1970: 1_786_451_400)
    private let presentation = GNOMEMetricPresentation(
        metric: UsageMetric(kind: .values, label: "Credits", used: 0),
        displayMode: .used,
        resetMode: .relative,
        timeFormat: .auto,
        alwaysShowPacing: false,
        now: Date(timeIntervalSince1970: 1_786_451_400),
        locale: Locale(identifier: "en_US_POSIX"),
        timeZone: TimeZone(secondsFromGMT: 0)!
    )

    @Test("Codex credits collapse a measured zero to one quiet dollar line")
    func creditsZeroIsQuiet() {
        let metric = UsageMetric(
            kind: .values,
            label: "Credits",
            used: 0,
            detail: "0 credits",
            values: [
                UsageValue(label: "", value: 0, unit: .dollars),
                UsageValue(label: "credits", value: 0, unit: .count),
            ]
        )

        #expect(GNOMEValuesCopy.primary(for: metric) == "$0.00")
        #expect(GNOMEValuesCopy.caption(for: metric, presentation: presentation) == nil)
        #expect(!GNOMEValuesCopy.primary(for: metric).contains("credits 0"))
        #expect(!GNOMEValuesCopy.primary(for: metric).contains("0 credits"))
    }

    @Test("Codex credits keep dollars and a human count when either is non-zero")
    func creditsNonZero() {
        let metric = UsageMetric(
            kind: .values,
            label: "Credits",
            used: 32.84,
            detail: "821 credits",
            values: [
                UsageValue(label: "", value: 32.84, unit: .dollars),
                UsageValue(label: "credits", value: 821, unit: .count),
            ]
        )

        #expect(GNOMEValuesCopy.primary(for: metric) == "$32.84 · 821 credits")
        #expect(GNOMEValuesCopy.caption(for: metric, presentation: presentation) == nil)

        let descriptive = UsageMetric(
            kind: .values,
            label: "Credits",
            used: 18.5,
            detail: "Flexible usage credits",
            values: [UsageValue(label: "credits", value: 37, unit: .credits)]
        )
        #expect(GNOMEValuesCopy.caption(for: descriptive, presentation: presentation) == "Flexible usage credits")
    }

    @Test("Rate Limit Resets never dumps the available key")
    func rateLimitResetsOmitsInternalKey() {
        let none = UsageMetric(
            kind: .values,
            label: "Rate Limit Resets",
            used: 0,
            values: [UsageValue(label: "available", value: 0, unit: .count)]
        )
        let some = UsageMetric(
            kind: .values,
            label: "Rate Limit Resets",
            used: 2,
            values: [UsageValue(label: "available", value: 2, unit: .count)],
            expiriesAt: [Date(timeIntervalSince1970: 1_786_451_400 + 7_200)]
        )

        #expect(GNOMEValuesCopy.primary(for: none, now: now) == "—")
        #expect(GNOMEValuesCopy.caption(for: none, presentation: presentation, now: now) == nil)
        #expect(GNOMEValuesCopy.primary(for: some, now: now) == "2 resets")
        #expect(GNOMEValuesCopy.caption(for: some, presentation: presentation, now: now) == "Expires in 2h")
        #expect(!GNOMEValuesCopy.primary(for: none).contains("available"))
        #expect(!GNOMEValuesCopy.primary(for: some).contains("available"))
    }

    @Test("Usage Limit Resets formats as N available, not a bare number")
    func usageLimitResetsKeepsAvailableCopy() {
        let none = UsageMetric(
            kind: .values,
            label: GrokRemainingResets.metricLabel,
            used: 0,
            values: [UsageValue(label: "available", value: 0, unit: .count)]
        )
        let some = UsageMetric(
            kind: .values,
            label: GrokRemainingResets.metricLabel,
            used: 1,
            values: [UsageValue(label: "available", value: 1, unit: .count)]
        )
        let rateNone = UsageMetric(
            kind: .values,
            label: "Rate Limit Resets",
            used: 0,
            values: [UsageValue(label: "available", value: 0, unit: .count)]
        )

        #expect(GNOMEValuesCopy.primary(for: none) == "0 available")
        #expect(GNOMEValuesCopy.primary(for: some) == "1 available")
        #expect(GNOMEValuesCopy.primary(for: rateNone, now: now) == "—")
    }

    @Test("Usage Limit Resets shows soonest expiry caption like Codex")
    func usageLimitResetsShowsSoonestExpiry() {
        let none = UsageMetric(
            kind: .values,
            label: GrokRemainingResets.metricLabel,
            used: 0,
            values: [UsageValue(label: "available", value: 0, unit: .count)]
        )
        let some = UsageMetric(
            kind: .values,
            label: GrokRemainingResets.metricLabel,
            used: 1,
            values: [UsageValue(label: "available", value: 1, unit: .count)],
            expiriesAt: [Date(timeIntervalSince1970: 1_786_451_400 + 7_200)]
        )

        #expect(GNOMEValuesCopy.primary(for: some, now: now) == "1 available")
        #expect(GNOMEValuesCopy.caption(for: some, presentation: presentation, now: now) == "Expires in 2h")
        #expect(GNOMEValuesCopy.caption(for: none, presentation: presentation, now: now) == nil)
    }

    @Test("Generic count labels stay human and spend rows stay joined")
    func genericCountsAndSpend() {
        #expect(GNOMEValuesCopy.formatValue(UsageValue(label: "credits", value: 0, unit: .count)) == "0 credits")
        #expect(GNOMEValuesCopy.formatValue(UsageValue(label: "available", value: 0, unit: .count)) == "0")
        #expect(GNOMEValuesCopy.formatValue(UsageValue(label: "tokens", value: 40, unit: .tokens)) == "40 tokens")

        let spend = UsageMetric(
            kind: .values,
            label: "Today",
            used: 4.08,
            values: [
                UsageValue(label: "", value: 4.08, unit: .dollars),
                UsageValue(label: "tokens", value: 40, unit: .tokens),
            ]
        )
        #expect(GNOMEValuesCopy.primary(for: spend) == "$4.08 · 40 tokens")
    }

    @Test("Usage Trend is omitted unless a day has real tokens")
    func emptyChartsAreHidden() {
        let empty = UsageMetric(kind: .chart, label: "Usage Trend", used: 0, points: [])
        let zeros = UsageMetric(
            kind: .chart,
            label: "Usage Trend",
            used: 0,
            points: [UsagePoint(date: Date(timeIntervalSince1970: 1_786_451_400), value: 0)]
        )
        let live = UsageMetric(
            kind: .chart,
            label: "Usage Trend",
            used: 40,
            points: [UsagePoint(date: Date(timeIntervalSince1970: 1_786_451_400), value: 40)]
        )

        #expect(GNOMEValuesCopy.shouldDisplay(empty) == false)
        #expect(GNOMEValuesCopy.shouldDisplay(zeros) == false)
        #expect(GNOMEValuesCopy.shouldDisplay(live) == true)
        #expect(GNOMEValuesCopy.shouldDisplay(UsageMetric(kind: .progress, label: "Weekly", used: 0, limit: 100)))
    }
}
