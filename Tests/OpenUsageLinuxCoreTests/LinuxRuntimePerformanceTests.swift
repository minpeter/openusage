import Foundation
import Testing
@testable import OpenUsageLinuxCore

@Suite("Linux runtime performance gates")
struct LinuxRuntimePerformanceTests {
    @Test("smaps rollup parser reads only the total proportional set size")
    func parsesPSS() throws {
        let fixture = """
        Rss:               42000 kB
        Pss:               12345 kB
        Pss_Dirty:          2345 kB
        """

        #expect(try LinuxProcessMemoryProbe.parsePSSBytes(fixture) == 12_641_280)
        #expect(throws: LinuxProcessMemoryProbeError.missingPSS) {
            try LinuxProcessMemoryProbe.parsePSSBytes("Rss: 42 kB")
        }
    }

    @Test("GTK p95 and memory gates use documented Linux budgets")
    func evaluatesRuntimeBudgets() {
        let passing = LinuxRuntimePerformanceReport(
            idlePSSBytes: 80 * 1_024 * 1_024,
            finalPSSBytes: 81 * 1_024 * 1_024,
            updateDurationsMilliseconds: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        )
        let slow = LinuxRuntimePerformanceReport(
            idlePSSBytes: 161 * 1_024 * 1_024,
            finalPSSBytes: 176 * 1_024 * 1_024,
            updateDurationsMilliseconds: [1, 2, 3, 4, 5, 6, 7, 8, 20, 25]
        )

        #expect(passing.updateP95Milliseconds == 10)
        #expect(passing.passesIdleMemoryGate)
        #expect(passing.passesGrowthGate)
        #expect(passing.passesGTKUpdateGate)
        #expect(passing.passes)
        #expect(!slow.passesIdleMemoryGate)
        #expect(!slow.passesGrowthGate)
        #expect(!slow.passesGTKUpdateGate)
        #expect(!slow.passes)

        let currentReleaseBaseline = LinuxRuntimePerformanceReport(
            idlePSSBytes: 122_304_512,
            finalPSSBytes: 124_000_000,
            updateDurationsMilliseconds: [8, 9, 10, 11, 12]
        )
        #expect(currentReleaseBaseline.passes)

        let ubuntu2404Baseline = LinuxRuntimePerformanceReport(
            idlePSSBytes: 152_172_544,
            finalPSSBytes: 153_000_000,
            updateDurationsMilliseconds: [8, 9, 10, 11, 12]
        )
        #expect(ubuntu2404Baseline.passes)
    }
}
