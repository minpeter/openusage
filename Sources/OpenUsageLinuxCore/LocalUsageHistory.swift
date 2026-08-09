import Foundation

public struct LocalModelUsage: Codable, Equatable, Sendable {
    public let model: String
    public let totalTokens: Int
    public let costUSD: Double
    public init(model: String, totalTokens: Int, costUSD: Double) {
        self.model = model; self.totalTokens = totalTokens; self.costUSD = costUSD
    }
}

public struct LocalUsageDay: Codable, Equatable, Sendable {
    public let date: String
    public let totalTokens: Int
    public let costUSD: Double
    public let models: [LocalModelUsage]
    public init(date: String, totalTokens: Int, costUSD: Double, models: [LocalModelUsage] = []) {
        self.date = date; self.totalTokens = totalTokens; self.costUSD = costUSD; self.models = models
    }
}

public struct LocalUsageScan: Codable, Equatable, Sendable {
    public let daily: [LocalUsageDay]
    public let unknownModelsByDay: [String: Set<String>]
    public init(daily: [LocalUsageDay], unknownModelsByDay: [String: Set<String>]) {
        self.daily = daily; self.unknownModelsByDay = unknownModelsByDay
    }
}

public enum LocalUsageHistory {
    public static let previousDays = 30

    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let values = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", values.year ?? 0, values.month ?? 0, values.day ?? 0)
    }

    public static func includedDayKeys(through now: Date, calendar: Calendar = .current) -> Set<String> {
        let today = calendar.startOfDay(for: now)
        return Set((0...previousDays).compactMap {
            calendar.date(byAdding: .day, value: -$0, to: today).map { dayKey($0, calendar: calendar) }
        })
    }

    public static func merge(_ scans: [LocalUsageScan], now: Date = Date(),
                             calendar: Calendar = .current) -> LocalUsageScan {
        let included = includedDayKeys(through: now, calendar: calendar)
        var totals: [String: Accumulator] = [:]
        var unknown: [String: Set<String>] = [:]
        for scan in scans {
            for day in scan.daily where included.contains(day.date) {
                let tokens = max(0, day.totalTokens)
                let cost = day.costUSD.isFinite ? max(0, day.costUSD) : 0
                totals[day.date, default: Accumulator()].add(tokens: tokens, cost: cost, models: day.models)
            }
            for (day, names) in scan.unknownModelsByDay where included.contains(day) {
                unknown[day, default: []].formUnion(names)
            }
        }
        return LocalUsageScan(daily: totals.map { date, value in value.day(date: date) }
            .sorted { $0.date > $1.date }, unknownModelsByDay: unknown)
    }

    struct Accumulator {
        var tokens = 0
        var cost = 0.0
        var models: [String: (name: String, tokens: Int, cost: Double)] = [:]
        mutating func add(tokens: Int, cost: Double, model: String) {
            self.tokens = saturatingAdd(self.tokens, tokens)
            self.cost = finiteAdd(self.cost, cost)
            let key = model.lowercased()
            var current = models[key] ?? (model, 0, 0)
            current.tokens = saturatingAdd(current.tokens, tokens)
            current.cost = finiteAdd(current.cost, cost)
            models[key] = current
        }
        mutating func add(tokens: Int, cost: Double, models values: [LocalModelUsage]) {
            self.tokens = saturatingAdd(self.tokens, tokens)
            self.cost = finiteAdd(self.cost, cost)
            for value in values {
                let key = value.model.lowercased()
                var current = models[key] ?? (value.model, 0, 0)
                current.tokens = saturatingAdd(current.tokens, max(0, value.totalTokens))
                current.cost = finiteAdd(current.cost, value.costUSD.isFinite ? max(0, value.costUSD) : 0)
                models[key] = current
            }
        }
        func day(date: String) -> LocalUsageDay {
            LocalUsageDay(date: date, totalTokens: tokens, costUSD: cost,
                models: models.values.map { LocalModelUsage(model: $0.name, totalTokens: $0.tokens, costUSD: $0.cost) }
                    .sorted { $0.model.localizedStandardCompare($1.model) == .orderedAscending })
        }
    }
}

public enum LocalSpendAggregator {
    public static func metrics(from scan: LocalUsageScan, now: Date = Date(),
                               calendar: Calendar = .current) -> [UsageMetric] {
        let bounded = LocalUsageHistory.merge([scan], now: now, calendar: calendar)
        let today = LocalUsageHistory.dayKey(now, calendar: calendar)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)
            .map { LocalUsageHistory.dayKey($0, calendar: calendar) }
        var result: [UsageMetric] = []
        appendPeriod(label: "Today", days: bounded.daily.filter { $0.date == today }, to: &result)
        appendPeriod(label: "Yesterday", days: bounded.daily.filter { $0.date == yesterday }, to: &result)
        appendPeriod(label: "Last 30 Days", days: bounded.daily, to: &result)
        let points = chartPoints(from: bounded, now: now, calendar: calendar)
        if !points.isEmpty {
            result.append(UsageMetric(kind: .chart, label: "Usage Trend", used: points.reduce(0) { finiteAdd($0, $1.value) }, points: points))
        }
        return result
    }

    private static func appendPeriod(label: String, days: [LocalUsageDay], to metrics: inout [UsageMetric]) {
        let tokens = days.reduce(0) { saturatingAdd($0, max(0, $1.totalTokens)) }
        let cost = days.reduce(0.0) { finiteAdd($0, $1.costUSD.isFinite ? max(0, $1.costUSD) : 0) }
        guard tokens > 0 || cost > 0 else { return }
        metrics.append(UsageMetric(kind: .values, label: label, used: cost, values: [
            UsageValue(label: "", value: cost, unit: .dollars),
            UsageValue(label: "tokens", value: Double(tokens), unit: .tokens),
        ]))
    }

    public static func chartPoints(from scan: LocalUsageScan, now: Date = Date(),
                                   calendar: Calendar = .current) -> [UsagePoint] {
        let values = Dictionary(uniqueKeysWithValues: scan.daily.map { ($0.date, Double(max(0, $0.totalTokens))) })
        guard values.values.contains(where: { $0.isFinite && $0 > 0 }) else { return [] }
        let today = calendar.startOfDay(for: now)
        return (0...LocalUsageHistory.previousDays).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let value = values[LocalUsageHistory.dayKey(date, calendar: calendar)] ?? 0
            return UsagePoint(date: date, value: value.isFinite && value >= 0 ? value : 0)
        }
    }
}

fileprivate func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? Int.max : sum
}

fileprivate func finiteAdd(_ lhs: Double, _ rhs: Double) -> Double {
    let sum = lhs + rhs
    return sum.isFinite ? sum : Double.greatestFiniteMagnitude
}
