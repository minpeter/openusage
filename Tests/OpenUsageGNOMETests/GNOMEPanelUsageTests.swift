import Foundation
import OpenUsageLinuxCore
import Testing
@testable import OpenUsageGNOME

@Suite("GNOME panel usage")
struct GNOMEPanelUsageTests {
    @Test("A provider accepts at most two distinct metric pins")
    func pinLimit() {
        let session = key("Session")
        let weekly = key("Weekly")
        let credits = key("Credits", kind: .value)
        var pins = PanelMetricPins()

        let insertions = [
            pins.pin(session, for: "claude"),
            pins.pin(weekly, for: "claude"),
            pins.pin(session, for: "claude"),
            pins.pin(credits, for: "claude"),
        ]
        #expect(insertions == [true, true, false, false])
        #expect(pins.pins(for: "claude") == [session, weekly])

        pins.unpin(session, for: "claude")
        let insertedCredits = pins.pin(credits, for: "claude")
        #expect(insertedCredits)
        #expect(pins.pins(for: "claude") == [weekly, credits])
    }

    @Test("Provider pins survive GNOME settings round trip")
    func settingsRoundTrip() throws {
        var settings = GNOMESettings()
        let insertions = [
            settings.panelMetricPins.pin(key("Session"), for: "claude"),
            settings.panelMetricPins.pin(key("Weekly"), for: "claude"),
        ]
        #expect(insertions == [true, true])

        let decoded = try JSONDecoder().decode(
            GNOMESettings.self,
            from: JSONEncoder().encode(settings)
        )

        #expect(decoded.panelMetricPins.pins(for: "claude") == [
            key("Session"),
            key("Weekly"),
        ])
    }

    @Test("Text style follows provider and pin order")
    func textStyle() {
        var pins = PanelMetricPins()
        let insertions = [
            pins.pin(key("Session"), for: "claude"),
            pins.pin(key("Weekly"), for: "claude"),
            pins.pin(key("Weekly"), for: "codex"),
        ]
        #expect(insertions == [true, true, true])
        let snapshots = [
            snapshot(
                providerID: "claude",
                name: "Claude",
                account: "Work",
                metrics: [progress("Weekly", 63), progress("Session", 95)]
            ),
            snapshot(
                providerID: "codex",
                name: "Codex",
                account: "Personal",
                metrics: [progress("Weekly", 71)]
            ),
        ]

        let configuration = PanelUsagePresentation.configuration(
            snapshots: snapshots,
            pins: pins,
            style: .text,
            displayMode: .mostUrgent
        )

        #expect(configuration.label == "Claude 95% 63% · Codex 71%")
        #expect(configuration.title == configuration.label)
        #expect(configuration.tooltip ==
            "Claude · Work · Session · 95% used | "
            + "Claude · Work · Weekly · 63% used | "
            + "Codex · Personal · Weekly · 71% used")
    }

    @Test("Bars style renders at most four bounded pins")
    func barsStyle() {
        var pins = PanelMetricPins()
        let pinResults = [
            pins.pin(key("One"), for: "alpha"),
            pins.pin(key("Two"), for: "alpha"),
            pins.pin(key("One"), for: "beta"),
            pins.pin(key("Two"), for: "beta"),
            pins.pin(key("One"), for: "gamma"),
        ]
        #expect(pinResults == [true, true, true, true, true])
        let snapshots = [
            snapshot(
                providerID: "alpha",
                name: "Alpha",
                metrics: [progress("One", 95), progress("Two", 63)]
            ),
            snapshot(
                providerID: "beta",
                name: "Beta",
                metrics: [progress("One", 71), progress("Two", 10)]
            ),
            snapshot(
                providerID: "gamma",
                name: "Gamma",
                metrics: [progress("One", 100)]
            ),
        ]

        let configuration = PanelUsagePresentation.configuration(
            snapshots: snapshots,
            pins: pins,
            style: .bars,
            displayMode: .mostUrgent
        )

        #expect(configuration.label == "█ ▅ ▆ ▂")
        #expect(configuration.tooltip.contains("Alpha · One · 95% used"))
        #expect(!configuration.tooltip.contains("Gamma"))
    }

    @Test("No pins preserve most-urgent and icon-only fallback")
    func fallback() {
        let snapshots = [
            snapshot(
                providerID: "claude",
                name: "Claude",
                metrics: [progress("Session", 82)]
            ),
        ]

        let visible = PanelUsagePresentation.configuration(
            snapshots: snapshots,
            pins: .init(),
            style: .bars,
            displayMode: .mostUrgent
        )
        let iconOnly = PanelUsagePresentation.configuration(
            snapshots: snapshots,
            pins: .init(),
            style: .text,
            displayMode: .iconOnly
        )

        #expect(visible.label == "Claude · 82%")
        #expect(iconOnly.label.isEmpty)
        #expect(iconOnly.tooltip == "Claude · Session · 82% used")
    }

    private func key(
        _ label: String,
        kind: UsageMetric.Kind = .progress
    ) -> MetricPreferenceKey {
        MetricPreferenceKey(metric: metric(label, kind: kind))
    }

    private func progress(_ label: String, _ percent: Double) -> UsageMetric {
        UsageMetric(kind: .progress, label: label, used: percent, limit: 100)
    }

    private func metric(
        _ label: String,
        kind: UsageMetric.Kind
    ) -> UsageMetric {
        UsageMetric(kind: kind, label: label, used: 1, limit: kind == .progress ? 10 : nil)
    }

    private func snapshot(
        providerID: String,
        name: String,
        account: String? = nil,
        metrics: [UsageMetric]
    ) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            providerID: providerID,
            instanceID: account.map { "\(providerID)-\($0)" } ?? providerID,
            displayName: name,
            accountLabel: account,
            plan: nil,
            metrics: metrics,
            links: [],
            refreshedAt: Date(timeIntervalSince1970: 0)
        )
    }
}
