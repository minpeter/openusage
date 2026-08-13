import Foundation

public enum SharedJSONCodec {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public enum SpendProjectionMath {
    public struct Value: Equatable, Sendable {
        public let id: String
        public let label: String
        public let amount: Double

        public init(id: String, label: String, amount: Double) {
            self.id = id
            self.label = label
            self.amount = amount
        }
    }

    public static func rankedPositive(_ values: [Value]) -> [Value] {
        values
            .filter { $0.amount.isFinite && $0.amount > 0 }
            .sorted {
                if $0.amount != $1.amount {
                    return $0.amount > $1.amount
                }
                return $0.label.localizedStandardCompare($1.label) == .orderedAscending
            }
    }

    public static func total(_ values: [Value]) -> Double {
        values.reduce(0) { $0 + $1.amount }
    }
}

public enum UsageThresholdMath {
    public static func normalizedRemaining(_ fraction: Double) -> Double {
        min(max(fraction.isFinite ? fraction : 1, 0), 1)
    }

    public static func isAlmostOut(_ remainingFraction: Double) -> Bool {
        self.normalizedRemaining(remainingFraction) < 0.1
    }
}
