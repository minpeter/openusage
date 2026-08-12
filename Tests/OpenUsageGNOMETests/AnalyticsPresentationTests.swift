import Foundation
import OpenUsageLinuxCore
import Testing
@testable import OpenUsageGNOME

@Suite("Analytics presentation")
struct AnalyticsPresentationTests {
    @Test("trend summaries use a readable nice scale")
    func trendSummary() {
        let points = [
            UsagePoint(date: Date(timeIntervalSince1970: 1_700_000_000), value: 10),
            UsagePoint(date: Date(timeIntervalSince1970: 1_700_086_400), value: 20),
            UsagePoint(date: Date(timeIntervalSince1970: 1_700_172_800), value: 30),
        ]

        let presentation = UsageTrendPresentation(points: points)

        #expect(presentation.total == 60)
        #expect(presentation.average == 20)
        #expect(presentation.peak?.value == 30)
        #expect(presentation.scaleMaximum == 40)
        #expect(presentation.gridValues == [0, 20, 40])
    }

    @Test("trend presentation remains bounded to the latest month")
    func trendBoundsPoints() {
        let points = (0..<40).map { index in
            UsagePoint(
                date: Date(timeIntervalSince1970: Double(index * 86_400)),
                value: Double(index)
            )
        }

        let presentation = UsageTrendPresentation(points: points)

        #expect(presentation.points.count == 31)
        #expect(presentation.points.first?.value == 9)
        #expect(presentation.points.last?.value == 39)
    }

    @Test("single provider spend uses a total treatment")
    func singleProviderSpend() {
        #expect(TotalSpendPresentationMode(sliceCount: 1) == .singleProvider)
    }

    @Test("multiple providers use ranked comparison bars")
    func multipleProviderSpend() {
        #expect(TotalSpendPresentationMode(sliceCount: 3) == .providerComparison)
    }
}
