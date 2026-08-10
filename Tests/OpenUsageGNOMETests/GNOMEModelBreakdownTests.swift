import OpenUsageLinuxCore
import Testing
@testable import OpenUsageGNOME

@Suite("GNOME model breakdown")
struct GNOMEModelBreakdownTests {
    @Test("Shares and whole percentages are deterministic")
    func shares() {
        let breakdown = GNOMEModelBreakdown(values: [
            UsageValue(label: "Sonnet", value: 30, unit: .tokens),
            UsageValue(label: "Opus", value: 60, unit: .tokens),
            UsageValue(label: "Haiku", value: 10, unit: .tokens),
        ])

        #expect(breakdown.total == 100)
        #expect(breakdown.items.map(\.label) == ["Opus", "Sonnet", "Haiku"])
        #expect(breakdown.items.map(\.share) == [0.6, 0.3, 0.1])
        #expect(breakdown.items.map(\.wholePercent) == [60, 30, 10])
        #expect(breakdown.accessibilityDescription == "Opus 60%, Sonnet 30%, Haiku 10%")
    }

    @Test("Ties preserve source order")
    func stableTies() {
        let breakdown = GNOMEModelBreakdown(values: [
            UsageValue(label: "Alpha", value: 20, unit: .dollars),
            UsageValue(label: "Beta", value: 20, unit: .dollars),
        ])

        #expect(breakdown.items.map(\.label) == ["Alpha", "Beta"])
    }

    @Test("Invalid and mixed-unit values do not corrupt shares")
    func invalidValues() {
        let breakdown = GNOMEModelBreakdown(values: [
            UsageValue(label: "Opus", value: 40, unit: .tokens),
            UsageValue(label: "Negative", value: -10, unit: .tokens),
            UsageValue(label: "Zero", value: 0, unit: .tokens),
            UsageValue(label: "NaN", value: .nan, unit: .tokens),
            UsageValue(label: "Cost", value: 10, unit: .dollars),
        ])

        #expect(breakdown.total == 40)
        #expect(breakdown.items.map(\.label) == ["Opus"])
        #expect(breakdown.items.first?.share == 1)
        #expect(breakdown.items.first?.wholePercent == 100)
    }

    @Test("Empty breakdown has no accessibility copy")
    func empty() {
        let breakdown = GNOMEModelBreakdown(values: [])

        #expect(breakdown.items.isEmpty)
        #expect(breakdown.total == 0)
        #expect(breakdown.accessibilityDescription.isEmpty)
    }
}
