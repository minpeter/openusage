import Foundation
import Testing
@testable import OpenUsageLinuxCore

@Suite("Total spend analytics")
struct TotalSpendAnalyticsTests {
    private let now = Date(timeIntervalSince1970: 1_786_579_200)

    @Test("Cost projection aggregates models and computes ring shares")
    func costProjection() {
        let projection = TotalSpendAnalytics.project(
            records: [
                record(providerID: "claude", providerName: "Claude", cost: 6, tokens: 1_000_000),
                record(providerID: "cursor", providerName: "Cursor", cost: 3, tokens: 2_000_000),
                record(providerID: "claude", providerName: "Claude", cost: 1, tokens: 500_000),
            ],
            metric: .cost,
            period: .thirtyDays,
            now: now
        )

        #expect(projection.total == 10)
        #expect(projection.slices.map(\.label) == ["Claude", "Cursor"])
        #expect(projection.slices.map(\.value) == [7, 3])
        #expect(projection.slices.map(\.share) == [0.7, 0.3])
        #expect(projection.slices.map(\.wholePercent) == [70, 30])
    }

    @Test("Token projection switches values without changing labels")
    func tokenProjection() {
        let projection = TotalSpendAnalytics.project(
            records: [
                record(providerID: "claude", providerName: "Claude", cost: 6, tokens: 1_000_000),
                record(providerID: "cursor", providerName: "Cursor", cost: 3, tokens: 2_000_000),
            ],
            metric: .tokens,
            period: .thirtyDays,
            now: now
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
            period: .thirtyDays,
            now: now
        )

        #expect(projection.total == 3.75)
        #expect(projection.slices.map(\.label) == ["Claude", "Cursor"])
        #expect(projection.slices.map(\.value) == [6, 1.5])
        #expect(projection.slices.map(\.share) == [0.8, 0.2])
    }

    @Test("Period filtering is inclusive and invalid records are ignored")
    func periodAndInvalidData() {
        let boundary = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let projection = TotalSpendAnalytics.project(
            records: [
                record(providerID: "boundary", providerName: "Boundary", cost: 2, tokens: 100, date: boundary),
                record(providerID: "old", providerName: "Old", cost: 50, tokens: 100, date: boundary.addingTimeInterval(-1)),
                record(providerID: "negative", providerName: "Negative", cost: -1, tokens: -2),
                record(providerID: "nan", providerName: "NaN", cost: .nan, tokens: .infinity),
            ],
            metric: .cost,
            period: .sevenDays,
            now: now
        )

        #expect(projection.total == 2)
        #expect(projection.slices.map(\.label) == ["Boundary"])
    }

    @Test("Empty projection is stable")
    func emptyProjection() {
        let projection = TotalSpendAnalytics.project(
            records: [],
            metric: .cost,
            period: .all,
            now: now
        )

        #expect(projection.total == 0)
        #expect(projection.slices.isEmpty)
    }

    private func record(
        providerID: String,
        providerName: String,
        cost: Double,
        tokens: Double,
        date: Date? = nil
    ) -> ProviderSpendRecord {
        ProviderSpendRecord(
            providerID: providerID,
            providerName: providerName,
            cost: cost,
            tokens: tokens,
            date: date ?? now.addingTimeInterval(-24 * 60 * 60)
        )
    }
}
