import Foundation
import OpenUsageCore

/// Which of a row's values a widget renders — the seam that lets one `.values` row back several tiles
/// (cost-only, tokens-only, both) while the data is produced exactly once.
enum ValueSelection: Hashable, Sendable {
    /// Every value, in order — the combined reading, e.g. "$4.08 · 1.2M tokens".
    case all
    /// Only the values of one kind: `.dollars` for a cost-only tile, `.count` for a tokens-only tile.
    case kind(MetricKind)

    func apply(to values: [MetricValue]) -> [MetricValue] {
        switch self {
        case .all:
            return values
        case .kind(let kind):
            return values.filter { $0.kind == kind }
        }
    }
}
