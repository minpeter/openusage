import Foundation
import Testing
@testable import OpenUsageLinuxCore

@Suite("Total spend analytics")
struct TotalSpendAnalyticsTests {
    private let now = Date(timeIntervalSince1970: 1_786_579_200)

    @Test("Cost projection preserves provider accounts and computes ring shares")
    func costProjection() {
        let projection = TotalSpendAnalytics.project(
            records: [
                record(instanceID: "claude-work", providerName: "Claude · Work", cost: 6, tokens: 1_000_000),
                record(instanceID: "cursor", providerName: "Cursor", cost: 3, tokens: 2_000_000),
                record(instanceID: "claude-personal", providerName: "Claude · Personal", cost: 1, tokens: 500_000),
            ],
            metric: .cost,
            period: .today
        )

        #expect(projection.total == 10)
        #expect(projection.slices.map(\.label) == [
            "Claude · Work",
            "Cursor",
            "Claude · Personal",
        ])
        #expect(projection.slices.map(\.value) == [6, 3, 1])
        #expect(projection.slices.map(\.wholePercent) == [60, 30, 10])
    }

    @Test("Token projection switches values without changing labels")
    func tokenProjection() {
        let projection = TotalSpendAnalytics.project(
            records: [
                record(providerID: "claude", providerName: "Claude", cost: 6, tokens: 1_000_000),
                record(providerID: "cursor", providerName: "Cursor", cost: 3, tokens: 2_000_000),
            ],
            metric: .tokens,
            period: .today
        )

        #expect(projection.total == 3_000_000)
        #expect(projection.slices.map(\.label) == ["Cursor", "Claude"])
        #expect(projection.slices.map(\.value) == [2_000_000, 1_000_000])
    }

    @Test("Cost per MTok uses per-model rates and a weighted center")
    func costPerMillionTokens() {
        let projection = TotalSpendAnalytics.project(
            records: [
                record(providerID: "claude", providerName: "Claude", cost: 12, tokens: 2_000_000),
                record(providerID: "cursor", providerName: "Cursor", cost: 3, tokens: 2_000_000),
            ],
            metric: .costPerMillionTokens,
            period: .today
        )

        #expect(projection.total == 3.75)
        #expect(projection.slices.map(\.label) == ["Claude", "Cursor"])
        #expect(projection.slices.map(\.value) == [6, 1.5])
        #expect(projection.slices.map(\.share) == [0.8, 0.2])
    }

    @Test("Period projection selects the exact macOS spend metric")
    func exactPeriodSelection() {
        let projection = TotalSpendAnalytics.project(
            records: [
                record(providerID: "claude", providerName: "Claude", cost: 2, tokens: 200, period: .today),
                record(providerID: "claude", providerName: "Claude", cost: 3, tokens: 300, period: .yesterday),
                record(providerID: "claude", providerName: "Claude", cost: 30, tokens: 3_000, period: .last30Days),
            ],
            metric: .cost,
            period: .yesterday
        )

        #expect(projection.total == 3)
        #expect(projection.slices.map(\.value) == [3])
    }

    @Test("Empty projection is stable")
    func emptyProjection() {
        let projection = TotalSpendAnalytics.project(
            records: [],
            metric: .cost,
            period: .today
        )

        #expect(projection.total == 0)
        #expect(projection.slices.isEmpty)
    }

    @Test("Snapshot extraction uses only exact period lines and account identity")
    func snapshotExtraction() {
        let snapshot = ProviderUsageSnapshot(
            providerID: "claude",
            instanceID: "claude-work",
            displayName: "Claude Studio",
            accountLabel: "Work",
            plan: nil,
            metrics: [
                UsageMetric(
                    kind: .values,
                    label: "Today",
                    used: 4.21,
                    values: [
                        UsageValue(label: "Total", value: 4.21, unit: .dollars),
                        UsageValue(label: "Tokens", value: 1_000_000, unit: .tokens),
                    ]
                ),
                UsageMetric(
                    kind: .values,
                    label: "Yesterday",
                    used: 3,
                    values: [
                        UsageValue(label: "Total", value: 3, unit: .dollars),
                        UsageValue(label: "Tokens", value: 2_000_000, unit: .tokens),
                    ]
                ),
                UsageMetric(
                    kind: .values,
                    label: "Last 30 Days",
                    used: 30,
                    values: [
                        UsageValue(label: "Total", value: 30, unit: .dollars),
                        UsageValue(label: "Tokens", value: 9_000_000, unit: .tokens),
                    ]
                ),
                UsageMetric(
                    kind: .values,
                    label: "Model Spend",
                    used: 100,
                    values: [
                        UsageValue(label: "Opus", value: 100, unit: .dollars),
                    ]
                ),
            ],
            links: [],
            refreshedAt: now
        )

        let records = TotalSpendAnalytics.records(from: [snapshot])

        #expect(records == [
            ProviderSpendRecord(
                providerID: "claude-work",
                providerName: "Claude Studio · Work",
                period: .today,
                cost: 4.21,
                tokens: 1_000_000
            ),
            ProviderSpendRecord(
                providerID: "claude-work",
                providerName: "Claude Studio · Work",
                period: .yesterday,
                cost: 3,
                tokens: 2_000_000
            ),
            ProviderSpendRecord(
                providerID: "claude-work",
                providerName: "Claude Studio · Work",
                period: .last30Days,
                cost: 30,
                tokens: 9_000_000
            ),
        ])
    }

    private func record(
        providerID: String,
        providerName: String,
        cost: Double,
        tokens: Double,
        period: TotalSpendPeriod = .today
    ) -> ProviderSpendRecord {
        ProviderSpendRecord(
            providerID: providerID,
            providerName: providerName,
            period: period,
            cost: cost,
            tokens: tokens
        )
    }

    private func record(
        instanceID: String,
        providerName: String,
        cost: Double,
        tokens: Double
    ) -> ProviderSpendRecord {
        record(
            providerID: instanceID,
            providerName: providerName,
            cost: cost,
            tokens: tokens
        )
    }
}
