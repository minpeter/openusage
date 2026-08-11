import Adwaita
import Foundation
import OpenUsageLinuxCore

enum GTKPerformanceProbeScenario {
    static func refreshingStates(sampleCount: Int) -> [Bool] {
        (0..<sampleCount).map { $0.isMultiple(of: 2) }
    }
}

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
            let warmupStates = GTKPerformanceProbeScenario.refreshingStates(
                sampleCount: 300
            )
            for (index, refreshing) in warmupStates.enumerated() {
                isRefreshing = refreshing
                stack.visibleChildName =
                    Self.pageOrder[index % Self.pageOrder.count].name
                applySnapshots()
                flushGTKPerformanceWork(waitForFrame: true)
            }
            isRefreshing = false
            stack.visibleChildName = Self.pageOrder[0].name
            applySnapshots()
            flushGTKPerformanceWork()
            let memory = LinuxProcessMemoryProbe()
            let idlePSS = try memory.readPSSBytes()
            let clock = ContinuousClock()
            var durations: [Double] = []
            durations.reserveCapacity(100)
            let states = GTKPerformanceProbeScenario.refreshingStates(
                sampleCount: 100
            )
            for (index, refreshing) in states.enumerated() {
                let started = clock.now
                isRefreshing = refreshing
                stack.visibleChildName =
                    Self.pageOrder[index % Self.pageOrder.count].name
                applySnapshots()
                flushGTKPerformanceWork()
                let components = started.duration(to: clock.now).components
                durations.append(
                    Double(components.seconds) * 1_000
                        + Double(components.attoseconds) / 1_000_000_000_000_000
                )
                flushGTKPerformanceWork(waitForFrame: true)
            }
            isRefreshing = false
            stack.visibleChildName = Self.pageOrder[0].name
            applySnapshots()
            window.visible = false
            window.present()
            flushGTKPerformanceWork(waitForFrame: true)
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
            let message = "Performance probe completed: p95 "
                + "\(report.updateP95Milliseconds) ms, "
                + "growth \(report.growthBytes) bytes, "
                + "idle \(report.idlePSSBytes) bytes"
            if report.passes {
                GNOMEAppLog.info(message)
            } else {
                GNOMEAppLog.error(message)
            }
        } catch {
            GNOMEAppLog.error(
                "Performance probe failed: \(error.localizedDescription)"
            )
        }
    }

    private func flushGTKPerformanceWork(waitForFrame: Bool = false) {
        while g_main_context_pending(nil) != 0 {
            _ = g_main_context_iteration(nil, 0)
        }
        if waitForFrame {
            _ = g_main_context_iteration(nil, 1)
            while g_main_context_pending(nil) != 0 {
                _ = g_main_context_iteration(nil, 0)
            }
        }
    }
}
