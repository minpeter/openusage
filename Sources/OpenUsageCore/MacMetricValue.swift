import Foundation

public enum MetricKind: String, Hashable, Sendable, Codable {
    case percent
    case dollars
    case count
}

public struct MetricValue: Hashable, Sendable, Codable {
    public var number: Double
    public var kind: MetricKind
    public var label: String?
    public var estimated: Bool

    public init(
        number: Double,
        kind: MetricKind,
        label: String? = nil,
        estimated: Bool = false)
    {
        self.number = number
        self.kind = kind
        self.label = label
        self.estimated = estimated
    }
}
