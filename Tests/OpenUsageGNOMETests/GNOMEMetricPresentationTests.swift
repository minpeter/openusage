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
