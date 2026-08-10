import Foundation

public enum TotalSpendMetric: String, CaseIterable, Codable, Sendable {
    case cost
    case costPerMillionTokens
    case tokens

    public var label: String {
        switch self {
        case .cost: "Cost"
        case .costPerMillionTokens: "Cost / MTok"
        case .tokens: "Tokens"
        }
    }
}

public enum TotalSpendPeriod: String, CaseIterable, Codable, Sendable {
    case sevenDays
    case thirtyDays
    case all

    public var label: String {
        switch self {
        case .sevenDays: "7 Days"
        case .thirtyDays: "30 Days"
        case .all: "All Time"
        }
    }
}

public struct ProviderSpendRecord: Equatable, Sendable {
    public let providerID: String
    public let providerName: String
    public let cost: Double
    public let tokens: Double
    public let date: Date

    public init(
        providerID: String,
        providerName: String,
        cost: Double,
        tokens: Double,
        date: Date
    ) {
        self.providerID = providerID
        self.providerName = providerName
        self.cost = cost
        self.tokens = tokens
        self.date = date
    }
}

public struct TotalSpendProjection: Equatable, Sendable {
    public struct Slice: Equatable, Sendable {
        public let providerID: String
        public let label: String
        public let value: Double
        public let share: Double
        public let wholePercent: Int

        public init(
            providerID: String,
            label: String,
            value: Double,
            share: Double,
            wholePercent: Int
        ) {
            self.providerID = providerID
            self.label = label
            self.value = value
            self.share = share
            self.wholePercent = wholePercent
        }
    }

    public let metric: TotalSpendMetric
    public let period: TotalSpendPeriod
    public let total: Double
    public let slices: [Slice]

    public init(
        metric: TotalSpendMetric,
        period: TotalSpendPeriod,
        total: Double,
        slices: [Slice]
    ) {
        self.metric = metric
        self.period = period
        self.total = total
        self.slices = slices
    }
}

public enum TotalSpendAnalytics {
    public static func project(
        records: [ProviderSpendRecord],
        metric: TotalSpendMetric,
        period: TotalSpendPeriod,
        now: Date = Date()
    ) -> TotalSpendProjection {
        let start = startDate(for: period, now: now)
        let filtered = records.filter { record in
            guard record.date <= now else { return false }
            guard let start else { return true }
            return record.date >= start
        }
        var aggregates: [String: ProviderAggregate] = [:]
        for record in filtered {
            var aggregate = aggregates[record.providerID] ?? .init(
                providerName: record.providerName,
                cost: 0,
                tokens: 0
            )
            if record.cost.isFinite, record.cost > 0 {
                aggregate.cost += record.cost
            }
            if record.tokens.isFinite, record.tokens > 0 {
                aggregate.tokens += record.tokens
            }
            aggregates[record.providerID] = aggregate
        }

        let values = aggregates.compactMap { providerID, aggregate -> ProviderValue? in
            let value: Double
            switch metric {
            case .cost:
                value = aggregate.cost
            case .costPerMillionTokens:
                guard aggregate.cost > 0, aggregate.tokens > 0 else { return nil }
                value = aggregate.cost / aggregate.tokens * 1_000_000
            case .tokens:
                value = aggregate.tokens
            }
            guard value.isFinite, value > 0 else { return nil }
            return .init(
                providerID: providerID,
                label: aggregate.providerName,
                value: value
            )
        }.sorted {
            if $0.value == $1.value {
                if $0.label == $1.label {
                    return $0.providerID < $1.providerID
                }
                return $0.label < $1.label
            }
            return $0.value > $1.value
        }

        let sliceTotal = values.reduce(0) { $0 + $1.value }
        let slices = values.map {
            let share = $0.value / sliceTotal
            return TotalSpendProjection.Slice(
                providerID: $0.providerID,
                label: $0.label,
                value: $0.value,
                share: share,
                wholePercent: Int((share * 100).rounded())
            )
        }
        let total: Double
        switch metric {
        case .cost:
            total = aggregates.values.reduce(0) { $0 + $1.cost }
        case .costPerMillionTokens:
            let totalCost = aggregates.values.reduce(0) { $0 + $1.cost }
            let totalTokens = aggregates.values.reduce(0) { $0 + $1.tokens }
            total = totalTokens > 0 ? totalCost / totalTokens * 1_000_000 : 0
        case .tokens:
            total = aggregates.values.reduce(0) { $0 + $1.tokens }
        }
        return .init(metric: metric, period: period, total: total, slices: slices)
    }

    private static func startDate(
        for period: TotalSpendPeriod,
        now: Date
    ) -> Date? {
        switch period {
        case .sevenDays: now.addingTimeInterval(-7 * 24 * 60 * 60)
        case .thirtyDays: now.addingTimeInterval(-30 * 24 * 60 * 60)
        case .all: nil
        }
    }
}

private struct ProviderAggregate {
    let providerName: String
    var cost: Double
    var tokens: Double
}

private struct ProviderValue {
    let providerID: String
    let label: String
    let value: Double
}
