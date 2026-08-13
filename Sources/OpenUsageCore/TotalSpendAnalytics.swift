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
    case today
    case yesterday
    case last30Days

    public var label: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .last30Days: "Last 30 Days"
        }
    }
}

public struct ProviderSpendRecord: Equatable, Sendable {
    public let providerID: String
    public let providerName: String
    public let period: TotalSpendPeriod
    public let cost: Double
    public let tokens: Double

    public init(
        providerID: String,
        providerName: String,
        period: TotalSpendPeriod,
        cost: Double,
        tokens: Double
    ) {
        self.providerID = providerID
        self.providerName = providerName
        self.period = period
        self.cost = cost
        self.tokens = tokens
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
    public static func records(
        from snapshots: [ProviderUsageSnapshot]
    ) -> [ProviderSpendRecord] {
        snapshots.flatMap { snapshot in
            let providerName = snapshot.accountLabel.map {
                "\(snapshot.displayName) · \($0)"
            } ?? snapshot.displayName
            return TotalSpendPeriod.allCases.compactMap {
                period -> ProviderSpendRecord? in
                guard let metric = snapshot.metrics.first(where: {
                    $0.kind == .values && $0.label == period.label
                }) else {
                    return nil
                }
                let cost = dimensionTotal(metric: metric, unit: .dollars) ?? 0
                let tokens = dimensionTotal(metric: metric, unit: .tokens) ?? 0
                guard cost > 0 || tokens > 0 else { return nil }
                return ProviderSpendRecord(
                    providerID: snapshot.instanceID,
                    providerName: providerName,
                    period: period,
                    cost: cost,
                    tokens: tokens
                )
            }
        }
    }

    public static func project(
        records: [ProviderSpendRecord],
        metric: TotalSpendMetric,
        period: TotalSpendPeriod
    ) -> TotalSpendProjection {
        let filtered = records.filter { $0.period == period }
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
            let complete = aggregates.values.filter {
                $0.cost > 0 && $0.tokens > 0
            }
            let totalCost = complete.reduce(0) { $0 + $1.cost }
            let totalTokens = complete.reduce(0) { $0 + $1.tokens }
            total = totalTokens > 0 ? totalCost / totalTokens * 1_000_000 : 0
        case .tokens:
            total = aggregates.values.reduce(0) { $0 + $1.tokens }
        }
        return .init(metric: metric, period: period, total: total, slices: slices)
    }

    private static func dimensionTotal(
        metric: UsageMetric,
        unit: UsageValue.Unit
    ) -> Double? {
        let total = (metric.values ?? []).reduce(0) { partial, value in
            guard value.unit == unit,
                  value.value.isFinite,
                  value.value > 0
            else {
                return partial
            }
            return partial + value.value
        }
        return total > 0 ? total : nil
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
