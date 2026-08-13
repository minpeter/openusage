import Foundation

public enum DelimitedUsageParser {
    public struct Row: Equatable, Sendable {
        public let tokens: Int
        public let cost: Double

        public init(tokens: Int, cost: Double) {
            self.tokens = tokens
            self.cost = cost
        }
    }

    public enum Error: Swift.Error, Equatable {
        case invalidHeader
        case invalidColumnCount
        case invalidNumber(String)
    }

    public static func parse(_ input: String) throws -> [Row] {
        let lines = input.split(whereSeparator: \.isNewline)
        guard let header = lines.first,
              header.split(separator: ",").map(String.init) == ["tokens", "cost"]
        else {
            throw Error.invalidHeader
        }

        return try lines.dropFirst().map { line in
            let columns = line.split(separator: ",", omittingEmptySubsequences: false)
            guard columns.count == 2 else {
                throw Error.invalidColumnCount
            }
            guard let tokens = Int(columns[0]) else {
                throw Error.invalidNumber(String(columns[0]))
            }
            guard let cost = Double(columns[1]) else {
                throw Error.invalidNumber(String(columns[1]))
            }
            return Row(tokens: tokens, cost: cost)
        }
    }
}
