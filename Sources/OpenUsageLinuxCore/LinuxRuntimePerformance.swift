import Foundation

public enum LinuxProcessMemoryProbeError: Error, Equatable {
    case missingPSS
}

public struct LinuxProcessMemoryProbe: Sendable {
    private let smapsRollup: URL

    public init(
        smapsRollup: URL = URL(fileURLWithPath: "/proc/self/smaps_rollup")
    ) {
        self.smapsRollup = smapsRollup
    }

    public func readPSSBytes() throws -> Int {
        try Self.parsePSSBytes(
            String(contentsOf: smapsRollup, encoding: .utf8)
        )
    }

    public static func parsePSSBytes(_ text: String) throws -> Int {
        for line in text.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2,
                  fields[0] == "Pss:",
                  let kibibytes = Int(fields[1])
            else {
                continue
            }
            return kibibytes * 1_024
        }
        throw LinuxProcessMemoryProbeError.missingPSS
    }
}

public struct LinuxRuntimePerformanceReport: Codable, Equatable, Sendable {
    public static let maximumIdlePSSBytes = 128 * 1_024 * 1_024
    public static let maximumGrowthBytes = 2 * 1_024 * 1_024
    public static let maximumUpdateP95Milliseconds = 16.0

    public let idlePSSBytes: Int
    public let finalPSSBytes: Int
    public let updateDurationsMilliseconds: [Double]

    public init(
        idlePSSBytes: Int,
        finalPSSBytes: Int,
        updateDurationsMilliseconds: [Double]
    ) {
        self.idlePSSBytes = idlePSSBytes
        self.finalPSSBytes = finalPSSBytes
        self.updateDurationsMilliseconds = updateDurationsMilliseconds
    }

    public var growthBytes: Int {
        max(0, finalPSSBytes - idlePSSBytes)
    }

    public var updateP95Milliseconds: Double {
        guard !updateDurationsMilliseconds.isEmpty else { return 0 }
        let sorted = updateDurationsMilliseconds.sorted()
        let rank = max(1, Int(ceil(Double(sorted.count) * 0.95)))
        return sorted[rank - 1]
    }

    public var passesIdleMemoryGate: Bool {
        idlePSSBytes <= Self.maximumIdlePSSBytes
    }

    public var passesGrowthGate: Bool {
        growthBytes <= Self.maximumGrowthBytes
    }

    public var passesGTKUpdateGate: Bool {
        updateP95Milliseconds < Self.maximumUpdateP95Milliseconds
    }

    public var passes: Bool {
        passesIdleMemoryGate && passesGrowthGate && passesGTKUpdateGate
    }
}
