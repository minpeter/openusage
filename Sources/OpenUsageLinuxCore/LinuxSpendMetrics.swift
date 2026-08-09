import Foundation

func linuxNumber(_ value: Any?) -> Double? {
    if let number = value as? NSNumber { return number.doubleValue }
    if let string = value as? String { return Double(string) }
    return nil
}

func stableProviderIdentity(_ source: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in source.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    return String(hash, radix: 16)
}

func linuxDayKey(_ date: Date, calendar: Calendar = .current) -> String {
    let values = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", values.year ?? 0, values.month ?? 0, values.day ?? 0)
}

func linuxSpendMetrics(
    totals: [String: (tokens: Int, cost: Double)],
    now: Date,
    calendar: Calendar = .current
) -> [UsageMetric] {
    let today = linuxDayKey(now, calendar: calendar)
    let yesterday = calendar.date(byAdding: .day, value: -1, to: now).map { linuxDayKey($0, calendar: calendar) }
    var metrics: [UsageMetric] = []
    func values(label: String, total: (tokens: Int, cost: Double)) -> UsageMetric {
        UsageMetric(kind: .values, label: label, used: total.cost, values: [
            UsageValue(label: "Cost", value: total.cost, unit: .dollars),
            UsageValue(label: "Tokens", value: Double(total.tokens), unit: .tokens),
        ])
    }
    if let total = totals[today], total.tokens > 0 || total.cost > 0 { metrics.append(values(label: "Today", total: total)) }
    if let yesterday, let total = totals[yesterday], total.tokens > 0 || total.cost > 0 {
        metrics.append(values(label: "Yesterday", total: total))
    }
    let all = totals.values.reduce(into: (tokens: 0, cost: 0.0)) { result, total in
        result.tokens += total.tokens
        result.cost += total.cost
    }
    if all.tokens > 0 || all.cost > 0 { metrics.append(values(label: "Last 30 Days", total: all)) }
    guard totals.values.contains(where: { $0.tokens > 0 }) else { return metrics }
    let start = calendar.startOfDay(for: now)
    let points = (0...30).reversed().compactMap { offset -> UsagePoint? in
        guard let day = calendar.date(byAdding: .day, value: -offset, to: start) else { return nil }
        return UsagePoint(date: day, value: Double(totals[linuxDayKey(day, calendar: calendar)]?.tokens ?? 0))
    }
    metrics.append(UsageMetric(
        kind: .chart, label: "Usage Trend", used: Double(all.tokens),
        detail: "From local logs (estimated)", points: Array(points.suffix(31))
    ))
    return metrics
}

func piReadBounded(_ url: URL, maximumBytes: Int) throws -> Data {
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard values.isRegularFile == true else { throw PiLinuxError.unreadableSession }
    guard (values.fileSize ?? maximumBytes + 1) <= maximumBytes else { throw PiLinuxError.localDataTooLarge }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
    guard data.count <= maximumBytes else { throw PiLinuxError.localDataTooLarge }
    return data
}

func piURL(expandingHome value: String, home: URL) -> URL {
    value == "~" ? home : value.hasPrefix("~/") ? home.appendingPathComponent(String(value.dropFirst(2))) : URL(fileURLWithPath: value)
}
func piTrimmed(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    return value
}
func piDate(_ value: String?) -> Date? {
    guard let value = piTrimmed(value) else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
}
