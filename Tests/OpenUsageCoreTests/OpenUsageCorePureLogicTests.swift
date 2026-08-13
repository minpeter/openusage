import Foundation
import OpenUsageCore
import Testing

@Suite("OpenUsageCore pricing")
struct OpenUsageCorePricingTests {
    @Test("token cost includes input output cache and reasoning rates")
    func tokenCost() {
        let rates = ModelRates(
            inputPerMillion: 2,
            outputPerMillion: 8,
            cacheWritePerMillion: 1,
            cacheReadPerMillion: 1)
        let tokens = TokenBreakdown(
            input: 1_000_000,
            cacheWrite5m: 0,
            cacheWrite1h: 0,
            cacheRead: 1_000_000,
            output: 500_000,
            isFast: false)

        #expect(rates.costDollars(for: tokens) == 7)
    }

    @Test("catalog lookup preserves macOS separator and numeric-version boundaries")
    func catalogLookupCompatibility() {
        let baseRates = ModelRates(
            inputPerMillion: 1,
            outputPerMillion: 2,
            cacheWritePerMillion: 1,
            cacheReadPerMillion: 0.1)
        let versionedRates = ModelRates(
            inputPerMillion: 3,
            outputPerMillion: 4,
            cacheWritePerMillion: 3,
            cacheReadPerMillion: 0.3)
        let catalog = PricingCatalog(entries: [
            "grok-4.3": baseRates,
            "claude-sonnet-4": baseRates,
            "claude-sonnet-4-5": versionedRates,
        ])

        #expect(catalog.findFuzzy("xai/grok-4-3")?.rates == baseRates)
        #expect(catalog.findFuzzy("claude-sonnet-4-20250514")?.rates == baseRates)
        #expect(catalog.findFuzzy("claude-sonnet-4-5-20250929")?.rates == versionedRates)
        #expect(catalog.findFuzzy("claude-sonnet-4-6") == nil)
    }

    @Test("cost and scaling preserve macOS cache and fast contracts")
    func costAndScalingCompatibility() {
        let rates = ModelRates(
            inputPerMillion: 2,
            outputPerMillion: 8,
            cacheWritePerMillion: 1,
            cacheReadPerMillion: 0.2,
            fastMultiplier: 3)
        let tokens = TokenBreakdown(
            input: 1_000_000,
            cacheWrite5m: 1_000_000,
            cacheWrite1h: 1_000_000,
            cacheRead: 1_000_000,
            output: 1_000_000)

        #expect(rates.costDollars(for: tokens) == 15.2)
        let scaled = rates.scaled(by: 3)
        #expect(scaled.inputPerMillion == 6)
        #expect(scaled.fastMultiplier == 1)
    }
}

@Suite("OpenUsageCore analytics")
struct OpenUsageCoreAnalyticsTests {
    @Test("provider shares are ranked and normalized")
    func providerShares() {
        let records = [
            ProviderSpendRecord(
                providerID: "claude",
                providerName: "Claude",
                period: .today,
                cost: 6,
                tokens: 3_000_000),
            ProviderSpendRecord(
                providerID: "codex",
                providerName: "Codex",
                period: .today,
                cost: 4,
                tokens: 2_000_000),
        ]

        let projection = TotalSpendAnalytics.project(
            records: records,
            metric: .cost,
            period: .today)

        #expect(projection.total == 10)
        #expect(projection.slices.map(\.providerID) == ["claude", "codex"])
        #expect(projection.slices.map(\.wholePercent) == [60, 40])
    }
}

@Suite("OpenUsageCore export")
struct OpenUsageCoreExportTests {
    @Test("JSON round-trip preserves provider snapshots")
    func roundTrip() throws {
        let service = UsageExportService(maximumImportBytes: 1_024)
        let snapshot = ProviderUsageSnapshot(
            providerID: "codex",
            displayName: "Codex",
            plan: "Pro",
            metrics: [],
            refreshedAt: Date(timeIntervalSince1970: 1_700_000_000))

        let data = try service.encode([snapshot], format: .json)
        #expect(try service.decodeJSON(data) == [snapshot])
    }

    @Test("oversized imports fail before decoding")
    func oversizedImport() {
        let service = UsageExportService(maximumImportBytes: 4)

        #expect(throws: UsageImportError.fileTooLarge(maximumBytes: 4)) {
            try service.decodeJSON(Data(repeating: 0, count: 5))
        }
    }
}

@Suite("OpenUsageCore notification policy")
struct OpenUsageCoreNotificationTests {
    @Test("almost-out transition fires only on threshold crossing")
    func thresholdCrossing() {
        let first = UsageThresholdNotificationPolicy.transitions(
            bucket: .healthy,
            remainingFraction: 0.11,
            resetsAt: nil,
            previous: .init(),
            toggles: .allEnabled)
        let crossed = UsageThresholdNotificationPolicy.transitions(
            bucket: .healthy,
            remainingFraction: 0.09,
            resetsAt: nil,
            previous: first.state,
            toggles: .allEnabled)

        #expect(first.milestones.isEmpty)
        #expect(crossed.milestones == [.almostOut])
    }

    @Test("threshold math clamps invalid input and uses strict ten percent")
    func thresholdMath() {
        #expect(UsageThresholdMath.normalizedRemaining(.nan) == 1)
        #expect(UsageThresholdMath.normalizedRemaining(-1) == 0)
        #expect(UsageThresholdMath.normalizedRemaining(2) == 1)
        #expect(UsageThresholdMath.isAlmostOut(0.09))
        #expect(!UsageThresholdMath.isAlmostOut(0.1))
    }
}

@Suite("OpenUsageCore shared policies")
struct OpenUsageCoreSharedPolicyTests {
    @Test("projection math ranks positive finite values")
    func projectionMath() {
        let ranked = SpendProjectionMath.rankedPositive([
            .init(id: "b", label: "Beta", amount: 2),
            .init(id: "a", label: "Alpha", amount: 2),
            .init(id: "zero", label: "Zero", amount: 0),
            .init(id: "nan", label: "NaN", amount: .nan),
        ])

        #expect(ranked.map(\.id) == ["a", "b"])
        #expect(SpendProjectionMath.total(ranked) == 4)
    }

    @Test("JSON codec preserves ISO dates")
    func jsonCodec() throws {
        struct Payload: Codable, Equatable {
            let date: Date
        }
        let value = Payload(date: Date(timeIntervalSince1970: 1_700_000_000))

        let data = try SharedJSONCodec.encoder().encode(value)
        #expect(try SharedJSONCodec.decoder().decode(Payload.self, from: data) == value)
    }
}

@Suite("OpenUsageCore provider parser")
struct OpenUsageCoreProviderParserTests {
    @Test("Cursor CSV parser streams quoted records")
    func cursorCSV() {
        let csv = """
        Date,Kind,Note
        2026-08-12,usage,"hello, world"
        """
        var records: [[String: String]] = []

        let summary = CursorCSVParser.forEachRecord(in: csv) {
            records.append($0)
        }

        #expect(summary.isStructurallyComplete)
        #expect(summary.rejectedRecordCount == 0)
        #expect(records == [[
            "Date": "2026-08-12",
            "Kind": "usage",
            "Note": "hello, world",
        ]])
    }

    @Test("delimited usage parser rejects malformed numeric input")
    func malformedInput() {
        #expect(throws: DelimitedUsageParser.Error.invalidNumber("oops")) {
            try DelimitedUsageParser.parse("tokens,cost\n100,1.25\n200,oops\n")
        }
    }

    @Test("delimited usage parser returns typed rows")
    func validInput() throws {
        let rows = try DelimitedUsageParser.parse(
            "tokens,cost\n100,1.25\n200,2.75\n")

        #expect(rows == [
            .init(tokens: 100, cost: 1.25),
            .init(tokens: 200, cost: 2.75),
        ])
    }
}
