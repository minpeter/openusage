import Testing
@testable import OpenUsageGNOME

@Suite("GNOME density")
struct GNOMEDensityTests {
    @Test("Compact density tightens visual rhythm without shrinking controls")
    func compactMetrics() {
        let regular = DensitySetting.regular.metrics
        let compact = DensitySetting.compact.metrics

        #expect(compact.outerMargin < regular.outerMargin)
        #expect(compact.sectionSpacing < regular.sectionSpacing)
        #expect(compact.rowSpacing < regular.rowSpacing)
        #expect(compact.controlSpacing < regular.controlSpacing)
        #expect(compact.minimumTargetHeight == regular.minimumTargetHeight)
        #expect(compact.minimumTargetHeight == 40)
    }
}
