import Foundation
import OpenUsageLinuxCore

extension DashboardController {
    func runPerformanceProbe() {
        guard DemoFixtures.isEnabled,
              let receiptPath = ProcessInfo.processInfo.environment[
                  "OPENUSAGE_PERFORMANCE_RECEIPT"
              ]
        else {
            return
        }
        do {
            if snapshots.isEmpty {
                snapshots = DemoFixtures.snapshots()
            }
            applySnapshots()
            let memory = LinuxProcessMemoryProbe()
            let idlePSS = try memory.readPSSBytes()
            let clock = ContinuousClock()
            var durations: [Double] = []
            durations.reserveCapacity(100)
            for _ in 0..<100 {
                let started = clock.now
                applySnapshots()
                let components = started.duration(to: clock.now).components
                durations.append(
                    Double(components.seconds) * 1_000
                        + Double(components.attoseconds) / 1_000_000_000_000_000
                )
            }
            let report = LinuxRuntimePerformanceReport(
                idlePSSBytes: idlePSS,
                finalPSSBytes: try memory.readPSSBytes(),
                updateDurationsMilliseconds: durations
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(
                to: URL(fileURLWithPath: receiptPath),
                options: .atomic
            )
            GNOMEAppLog.info(
                "Performance probe completed: p95 "
                    + "\(report.updateP95Milliseconds) ms, growth \(report.growthBytes) bytes"
            )
        } catch {
            GNOMEAppLog.error(
                "Performance probe failed: \(error.localizedDescription)"
            )
        }
    }
}
