import Foundation
import OpenUsageLinuxCore
import Testing
@testable import OpenUsageGNOME

@Suite("GNOME metric layout")
struct GNOMEMetricLayoutTests {
    @Test("New metrics seed as enabled and always visible in provider order")
    func seedsProviderOrder() {
        let metrics = [
            metric("Session"),
            metric("Weekly"),
            metric("Credits", kind: .value),
        ]
        var layout = ProviderMetricLayout()

        layout.reconcile(with: metrics)

        #expect(layout.entries.map(\.key) == metrics.map(MetricPreferenceKey.init(metric:)))
        #expect(layout.entries.allSatisfy { $0.isEnabled })
        #expect(layout.entries.allSatisfy { $0.section == .alwaysVisible })
        #expect(layout.displayedMetrics(from: metrics, in: .alwaysVisible).map(\.label) == [
            "Session",
            "Weekly",
            "Credits",
        ])
        #expect(layout.displayedMetrics(from: metrics, in: .onDemand).isEmpty)
    }

    @Test("Enablement, section, and order survive metric reconciliation")
    func preservesCustomizationAndTombstones() {
        let session = MetricPreferenceKey(metric: metric("Session"))
        let weekly = MetricPreferenceKey(metric: metric("Weekly"))
        let credits = MetricPreferenceKey(metric: metric("Credits", kind: .value))
        let removed = MetricPreferenceKey(metric: metric("Removed"))
        let newMetric = metric("New")
        var layout = ProviderMetricLayout(entries: [
            .init(key: weekly, isEnabled: true, section: .onDemand),
            .init(key: session, isEnabled: true, section: .alwaysVisible),
            .init(key: credits, isEnabled: false, section: .alwaysVisible),
            .init(key: removed, isEnabled: true, section: .onDemand),
        ])

        let metrics = [
            metric("Session"),
            metric("Weekly"),
            metric("Credits", kind: .value),
            newMetric,
        ]
        layout.reconcile(with: metrics)

        #expect(layout.entries.map(\.key).contains(removed))
        #expect(layout.entry(for: credits)?.isEnabled == false)
        #expect(layout.displayedMetrics(from: metrics, in: .alwaysVisible).map(\.label) == [
            "Session",
            "New",
        ])
        #expect(layout.displayedMetrics(from: metrics, in: .onDemand).map(\.label) == ["Weekly"])
    }

    @Test("Disabled metrics retain their divider position and reorder on enable")
    func disabledMetricKeepsSectionAndOrder() {
        let metrics = [metric("Session"), metric("Weekly"), metric("Credits", kind: .value)]
        let weekly = MetricPreferenceKey(metric: metrics[1])
        var layout = ProviderMetricLayout()
        layout.reconcile(with: metrics)

        layout.move(weekly, to: .onDemand, at: 0)
        layout.setEnabled(false, for: weekly)
        #expect(layout.displayedMetrics(from: metrics, in: .onDemand).isEmpty)

        layout.setEnabled(true, for: weekly)
        #expect(layout.entry(for: weekly)?.section == .onDemand)
        #expect(layout.displayedMetrics(from: metrics, in: .onDemand).map(\.label) == ["Weekly"])
    }

    @Test("Persisted Auto/API/Total labels migrate to Cursor Models and Other Models")
    func migratesCursorSpendingLabels() throws {
        let auto = MetricPreferenceKey(kind: "progress", label: "Auto usage")
        let api = MetricPreferenceKey(kind: "progress", label: "API usage")
        let total = MetricPreferenceKey(kind: "progress", label: "Total usage")
        var settings = GNOMESettings()
        settings.metricLayouts["cursor"] = ProviderMetricLayout(entries: [
            .init(key: auto, isEnabled: true, section: .alwaysVisible),
            .init(key: api, isEnabled: true, section: .alwaysVisible),
            .init(key: total, isEnabled: false, section: .onDemand),
        ])
        _ = settings.panelMetricPins.pin(auto, for: "cursor")
        _ = settings.panelMetricPins.pin(api, for: "cursor")

        let decoded = try JSONDecoder().decode(
            GNOMESettings.self,
            from: JSONEncoder().encode(settings)
        )
        let layout = try #require(decoded.metricLayouts["cursor"])
        #expect(layout.entries.map(\.key.label) == ["Cursor Models", "Other Models"])
        #expect(layout.entry(for: MetricPreferenceKey(kind: "progress", label: "Cursor Models"))?.isEnabled == true)
        #expect(layout.entry(for: MetricPreferenceKey(kind: "progress", label: "Other Models"))?.isEnabled == true)
        #expect(decoded.panelMetricPins.pins(for: "cursor").map(\.label) == [
            "Cursor Models", "Other Models",
        ])
        #expect(layout.entries.contains { $0.key.label == "Auto usage" } == false)
        #expect(layout.entries.contains { $0.key.label == "Total usage" } == false)
    }

    @Test("Persisted Grok Bot weekly and Antigravity Claude labels migrate")
    func migratesRenamedMetricLabels() throws {
        let grokBot = MetricPreferenceKey(kind: "progress", label: "Grok Bot weekly")
        let claude = MetricPreferenceKey(kind: "progress", label: "Claude")
        let claudeWeekly = MetricPreferenceKey(kind: "progress", label: "Claude Weekly")
        var settings = GNOMESettings()
        settings.metricLayouts["cursor"] = ProviderMetricLayout(entries: [
            .init(key: grokBot, isEnabled: true, section: .alwaysVisible),
        ])
        settings.metricLayouts["antigravity"] = ProviderMetricLayout(entries: [
            .init(key: claude, isEnabled: true, section: .alwaysVisible),
            .init(key: claudeWeekly, isEnabled: true, section: .onDemand),
        ])
        _ = settings.panelMetricPins.pin(grokBot, for: "cursor")
        _ = settings.panelMetricPins.pin(claudeWeekly, for: "antigravity")

        let decoded = try JSONDecoder().decode(
            GNOMESettings.self,
            from: JSONEncoder().encode(settings)
        )

        #expect(decoded.metricLayouts["cursor"]?.entries.map(\.key.label) == ["Grok Bot Weekly"])
        #expect(decoded.metricLayouts["antigravity"]?.entries.map(\.key.label) == [
            "Third-Party", "Third-Party Weekly",
        ])
        #expect(decoded.panelMetricPins.pins(for: "cursor").map(\.label) == ["Grok Bot Weekly"])
        #expect(decoded.panelMetricPins.pins(for: "antigravity").map(\.label) == ["Third-Party Weekly"])
    }

    @Test("Provider metric layouts survive GNOME settings round trip")
    func settingsRoundTrip() throws {
        let weekly = MetricPreferenceKey(metric: metric("Weekly"))
        var settings = GNOMESettings()
        settings.metricLayouts["claude"] = ProviderMetricLayout(entries: [
            .init(key: weekly, isEnabled: true, section: .onDemand),
        ])

        let decoded = try JSONDecoder().decode(
            GNOMESettings.self,
            from: JSONEncoder().encode(settings)
        )

        #expect(decoded.metricLayouts["claude"]?.entries == [
            .init(key: weekly, isEnabled: true, section: .onDemand),
        ])
    }

    private func metric(
        _ label: String,
        kind: UsageMetric.Kind = .progress
    ) -> UsageMetric {
        UsageMetric(kind: kind, label: label, used: 1, limit: kind == .progress ? 10 : nil)
    }
}
