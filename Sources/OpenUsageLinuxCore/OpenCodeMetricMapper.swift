import Foundation

enum OpenCodeMetricMapper {
    static func capMetrics(_ windows: OpenCodeGoWindows) -> [UsageMetric] {
        [
            UsageMetric(kind: .progress, label: "Session", used: windows.sessionSpend, limit: 12, resetsAt: windows.sessionResetsAt),
            UsageMetric(kind: .progress, label: "Weekly", used: windows.weeklySpend, limit: 30, resetsAt: windows.weeklyResetsAt),
            UsageMetric(kind: .progress, label: "Monthly", used: windows.monthlySpend, limit: 60, resetsAt: windows.monthlyResetsAt),
        ]
    }

    static func historyMetrics(rows: [OpenCodeLocalScanner.Row], now: Date) -> [UsageMetric] {
        let since = Calendar.current.date(byAdding: .day, value: -30, to: Calendar.current.startOfDay(for: now)) ?? now
        let recent = rows.filter { Date(timeIntervalSince1970: $0.ms / 1000) >= since }
        var byDay: [String: (cost: Double, tokens: Int)] = [:]
        for row in recent {
            let key = dayKey(Date(timeIntervalSince1970: row.ms / 1000))
            byDay[key, default: (0, 0)].cost += row.cost
            byDay[key, default: (0, 0)].tokens += row.tokens
        }
        let today = dayKey(now)
        let yesterdayDate = Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now
        let yesterday = dayKey(yesterdayDate)
        var metrics: [UsageMetric] = []
        if let value = byDay[today], value.cost > 0 || value.tokens > 0 { metrics.append(values(label: "Today", value)) }
        if let value = byDay[yesterday], value.cost > 0 || value.tokens > 0 { metrics.append(values(label: "Yesterday", value)) }
        let total = byDay.values.reduce(into: (cost: 0.0, tokens: 0)) { result, value in
            result.cost += value.cost; result.tokens += value.tokens
        }
        if total.cost > 0 || total.tokens > 0 { metrics.append(values(label: "Last 30 Days", total)) }
        if byDay.values.contains(where: { $0.tokens > 0 }) {
            let start = Calendar.current.startOfDay(for: now)
            let points = (0...30).reversed().compactMap { offset -> UsagePoint? in
                guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: start) else { return nil }
                return UsagePoint(date: date, value: Double(byDay[dayKey(date)]?.tokens ?? 0))
            }
            metrics.append(UsageMetric(kind: .chart, label: "Usage Trend", used: 0,
                                       detail: "From your OpenCode logs", points: points))
        }
        return metrics
    }

    private static func values(label: String, _ value: (cost: Double, tokens: Int)) -> UsageMetric {
        UsageMetric(kind: .values, label: label, used: 0, values: [
            UsageValue(label: "Cost", value: rounded(value.cost), unit: .dollars),
            UsageValue(label: "Tokens", value: Double(value.tokens), unit: .tokens),
        ])
    }

    private static func dayKey(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func rounded(_ value: Double) -> Double { (value * 10_000).rounded() / 10_000 }
}
