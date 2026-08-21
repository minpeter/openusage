import Foundation
import OpenUsageLinuxCore
import Testing
@testable import OpenUsageGNOME

@Suite("GNOME metric presentation")
struct GNOMEMetricPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_786_451_400)

    @Test("Progress values honor Used and Left")
    func usedAndLeft() {
        let metric = progress(used: 42)

        let used = presentation(metric, displayMode: .used)
        let remaining = presentation(metric, displayMode: .remaining)

        #expect(used.valueText == "42% used")
        #expect(remaining.valueText == "58% left")
    }

    @Test("Reset labels honor countdown and exact 12/24 hour time")
    func resetModes() {
        let reset = now.addingTimeInterval(5_400)
        let metric = progress(used: 42, resetsAt: reset)

        let countdown = presentation(metric, resetMode: .relative)
        let twelveHour = presentation(
            metric,
            resetMode: .absolute,
            timeFormat: .twelveHour
        )
        let twentyFourHour = presentation(
            metric,
            resetMode: .absolute,
            timeFormat: .twentyFourHour
        )

        #expect(countdown.resetText == "Resets in 1h")
        #expect(twelveHour.resetText == "Resets today at 2:00 PM")
        #expect(twentyFourHour.resetText == "Resets today at 14:00")
    }

    @Test("Pacing is quiet when healthy unless Always Show Pacing is enabled")
    func healthyPacingVisibility() {
        let metric = progress(
            used: 30,
            resetsAt: now.addingTimeInterval(7_200),
            periodDurationMilliseconds: 14_400_000
        )

        let defaultPresentation = presentation(metric, alwaysShowPacing: false)
        let alwaysVisible = presentation(metric, alwaysShowPacing: true)

        #expect(defaultPresentation.pacingText == nil)
        #expect(alwaysVisible.pacingText == "On pace · ~60% at reset")
    }

    @Test("Risky pacing remains visible at default settings")
    func riskyPacingVisibility() {
        let close = progress(
            used: 48,
            resetsAt: now.addingTimeInterval(7_200),
            periodDurationMilliseconds: 14_400_000
        )
        let runningOut = progress(
            used: 60,
            resetsAt: now.addingTimeInterval(7_200),
            periodDurationMilliseconds: 14_400_000
        )

        #expect(presentation(close).pacingText == "Close · ~96% at reset")
        #expect(presentation(runningOut).pacingText == "Will run out · ~120% at reset")
    }

    @Test("Metrics without a usable window omit pacing")
    func missingPacingWindow() {
        #expect(presentation(progress(used: 80)).pacingText == nil)
        #expect(presentation(
            progress(used: 80, resetsAt: now.addingTimeInterval(3_600))
        ).pacingText == nil)
    }

    @Test("Negative provider usage clamps pacing to zero")
    func negativeUsage() {
        let metric = progress(
            used: -10,
            resetsAt: now.addingTimeInterval(7_200),
            periodDurationMilliseconds: 14_400_000
        )
        let result = presentation(metric, alwaysShowPacing: true)

        #expect(result.valueText == "0% used")
        #expect(result.pacingText == "On pace · ~0% at reset")
    }

    @Test("Quota captions never show a raw millisecond period")
    func hidesRawMillisecondPeriods() {
        #expect(GNOMEFormat.period(milliseconds: 604_800_000) == "1 week")
        #expect(GNOMEFormat.metricDetail("604800000 ms period") == "1 week")
        #expect(GNOMEFormat.metricDetail("86400000 ms period") == "1 day")
        #expect(GNOMEFormat.metricDetail("From local logs") == "From local logs")
        #expect(GNOMEFormat.metricDetail("604800000 ms period")?.contains("ms") != true)
    }

    @Test("Cursor Models and Other Models present Spending percents including a real 0%")
    func cursorSpendingPoolsPresentation() {
        let models = UsageMetric(
            kind: .progress,
            label: "Cursor Models",
            used: 1,
            limit: 100,
            resetsAt: Date(timeIntervalSince1970: 1_772_592_000),
            periodDurationMilliseconds: 2_592_000_000,
            detail: "Includes Cursor Grok and Composer"
        )
        let other = UsageMetric(
            kind: .progress,
            label: "Other Models",
            used: 0,
            limit: 100,
            resetsAt: Date(timeIntervalSince1970: 1_772_592_000),
            periodDurationMilliseconds: 2_592_000_000
        )
        let modelsPresentation = presentation(models)
        let otherPresentation = presentation(other)

        #expect(models.label == "Cursor Models")
        #expect(models.label != "Auto usage")
        #expect(models.label != "Total usage")
        #expect(other.label == "Other Models")
        #expect(other.label != "API usage")
        #expect(modelsPresentation.valueText == "1% used")
        #expect(otherPresentation.valueText == "0% used")
        #expect(GNOMEFormat.metricDetail(models.detail) == "Includes Cursor Grok and Composer")
    }

    @Test("Cursor Grok Bot Weekly presents used percent and weekly reset, not Grok CLI Weekly")
    func cursorGrokBotWeeklyPresentation() {
        let metric = UsageMetric(
            kind: .progress,
            label: "Grok Bot Weekly",
            used: 13,
            limit: 100,
            resetsAt: Date(timeIntervalSince1970: 1_787_788_800),
            periodDurationMilliseconds: 604_800_000,
            detail: "percent"
        )
        let relative = presentation(metric, resetMode: .relative)
        let absolute = presentation(metric, resetMode: .absolute, timeFormat: .twentyFourHour)

        #expect(metric.label == "Grok Bot Weekly")
        #expect(metric.label != "Weekly limit")
        #expect(relative.valueText == "13% used")
        #expect(relative.resetText == "Resets in 15d 11h")
        #expect(absolute.resetText == "Resets Aug 27 at 00:00")
        #expect(GNOMEFormat.period(milliseconds: 604_800_000) == "1 week")
        #expect(GNOMEFormat.metricDetail(metric.detail) == nil)
        #expect(GNOMEFormat.metricDetail(metric.detail)?.contains("percent") != true)
    }

    @Test("Overview copy mentions spend only when a Total Spend card can show")
    func overviewCopyFollowsSpendCard() {
        #expect(
            GNOMEPageCopy.overviewDescription(hasSpend: true)
                == "Your spend, quota pressure, and provider health at a glance."
        )
        #expect(
            GNOMEPageCopy.overviewDescription(hasSpend: false)
                == "Your quota pressure and provider health at a glance."
        )
        #expect(!GNOMEPageCopy.providersGroupDescription.lowercased().contains("spend"))
    }

    @Test("Disabled badges use a muted color instead of success green")
    func disabledBadgeIsNotSuccess() {
        #expect(GNOMEBadgeStyle.semanticClass(for: "Disabled") == .dimLabel)
        #expect(GNOMEBadgeStyle.semanticClass(for: "Unavailable") == .dimLabel)
        #expect(GNOMEBadgeStyle.semanticClass(for: "100 cap") == .success)
        #expect(GNOMEBadgeStyle.semanticClass(for: "Error") == .error)
    }

    @Test("GNOME settings produce renderer presentation options")
    func settingsBridge() {
        var settings = GNOMESettings()
        settings.widgetDisplayMode = .remaining
        settings.resetDisplayMode = .absolute
        settings.timeFormat = .twentyFourHour
        settings.alwaysShowPacing = true
        let metric = progress(
            used: 30,
            resetsAt: now.addingTimeInterval(7_200),
            periodDurationMilliseconds: 14_400_000
        )

        let presentation = settings.metricPresentationSettings.presentation(
            for: metric,
            now: now,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(presentation.valueText == "70% left")
        #expect(presentation.resetText == "Resets today at 14:30")
        #expect(presentation.pacingText == "On pace · ~60% at reset")
    }

    private func presentation(
        _ metric: UsageMetric,
        displayMode: WidgetDisplayMode = .used,
        resetMode: ResetDisplayMode = .relative,
        timeFormat: TimeFormatSetting = .auto,
        alwaysShowPacing: Bool = false
    ) -> GNOMEMetricPresentation {
        GNOMEMetricPresentation(
            metric: metric,
            displayMode: displayMode,
            resetMode: resetMode,
            timeFormat: timeFormat,
            alwaysShowPacing: alwaysShowPacing,
            now: now,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
    }

    private func progress(
        used: Double,
        resetsAt: Date? = nil,
        periodDurationMilliseconds: Int? = nil
    ) -> UsageMetric {
        UsageMetric(
            kind: .progress,
            label: "Session",
            used: used,
            limit: 100,
            resetsAt: resetsAt,
            periodDurationMilliseconds: periodDurationMilliseconds
        )
    }
}
