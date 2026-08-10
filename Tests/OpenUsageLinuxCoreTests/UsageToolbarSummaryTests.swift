import Foundation
import Testing
@testable import OpenUsageLinuxCore

@Suite("Usage toolbar summary")
struct UsageToolbarSummaryTests {
    @Test("Most urgent healthy quota becomes the toolbar summary")
    func selectsMostUrgentQuota() {
        let summary = UsageToolbarSummary.mostUrgent(in: [
            snapshot(providerID: "claude", name: "Claude", metric: quota("Session", used: 82)),
            snapshot(providerID: "codex", name: "Codex", metric: quota("Weekly", used: 47)),
            .error(providerID: "broken", displayName: "Broken", message: "No session"),
        ])

        #expect(summary?.providerID == "claude")
        #expect(summary?.providerName == "Claude")
        #expect(summary?.metricLabel == "Session")
        #expect(summary?.percentUsed == 82)
        #expect(summary?.severity == .warning)
        #expect(summary?.compactLabel == "Claude · 82%")
        #expect(summary?.accessibilityDescription == "Claude, Session, 82% used")
    }

    @Test("Critical usage is clamped and equal urgency keeps presentation order")
    func clampsAndKeepsPresentationOrder() {
        let summary = UsageToolbarSummary.mostUrgent(in: [
            snapshot(providerID: "first", name: "First", metric: quota("Weekly", used: 120)),
            snapshot(providerID: "second", name: "Second", metric: quota("Session", used: 120)),
        ])

        #expect(summary?.providerID == "first")
        #expect(summary?.percentUsed == 100)
        #expect(summary?.severity == .critical)
    }

    @Test("Snapshots without a healthy progress quota have no summary")
    func excludesErrorsAndNonProgressMetrics() {
        let value = UsageMetric(kind: .value, label: "Balance", used: 12)
        let summary = UsageToolbarSummary.mostUrgent(in: [
            snapshot(providerID: "value", name: "Value", metric: value),
            ProviderUsageSnapshot(
                providerID: "stale",
                instanceID: "stale",
                displayName: "Stale",
                accountLabel: nil,
                plan: nil,
                metrics: [quota("Session", used: 95)],
                links: [],
                refreshedAt: Date(timeIntervalSince1970: 0),
                errorMessage: "Refresh failed"
            ),
        ])

        #expect(summary == nil)
    }

    @Test("Most urgent is the persisted tray display default")
    func mostUrgentIsDefaultTrayDisplay() throws {
        #expect(TrayUsageDisplayMode.defaultValue == .mostUrgent)

        let encoded = try JSONEncoder().encode(TrayUsageDisplayMode.iconOnly)
        #expect(try JSONDecoder().decode(TrayUsageDisplayMode.self, from: encoded) == .iconOnly)
    }

    @Test("Tray display mode chooses usage text or icon-only metadata")
    func trayDisplayModeBuildsConfiguration() {
        let snapshots = [
            snapshot(providerID: "grok", name: "Grok", metric: quota("Weekly", used: 36)),
            snapshot(providerID: "claude", name: "Claude", metric: quota("Session", used: 82)),
        ]

        let visible = StatusNotifierItemConfiguration.usage(
            snapshots: snapshots,
            displayMode: .mostUrgent
        )
        #expect(visible.title == "Claude · 82%")
        #expect(visible.label == "Claude · 82%")
        #expect(visible.tooltip == "Session · 82% used")

        let iconOnly = StatusNotifierItemConfiguration.usage(
            snapshots: snapshots,
            displayMode: .iconOnly
        )
        #expect(iconOnly.title == "OpenUsage")
        #expect(iconOnly.label.isEmpty)
        #expect(iconOnly.tooltip == "Claude · Session · 82% used")
    }

    private func quota(_ label: String, used: Double) -> UsageMetric {
        UsageMetric(kind: .progress, label: label, used: used, limit: 100)
    }

    private func snapshot(
        providerID: String,
        name: String,
        metric: UsageMetric
    ) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            providerID: providerID,
            instanceID: providerID,
            displayName: name,
            accountLabel: nil,
            plan: nil,
            metrics: [metric],
            links: [],
            refreshedAt: Date(timeIntervalSince1970: 0)
        )
    }
}
