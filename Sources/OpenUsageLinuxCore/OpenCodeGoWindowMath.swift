import Foundation

struct OpenCodeGoWindowMath {
    static func compute(costs: [(ms: Double, cost: Double)], anchorMs: Double?, now: Date) -> OpenCodeGoWindows {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let nowMs = now.timeIntervalSince1970 * 1000
        let sessionStart = nowMs - 5 * 60 * 60 * 1000
        let sessionRows = costs.filter { $0.ms >= sessionStart && $0.ms < nowMs }
        let fiveHoursMs = 5.0 * 60 * 60 * 1000
        let oldestSessionMs = sessionRows.map(\.ms).min() ?? nowMs
        let sessionReset = Date(timeIntervalSince1970: (oldestSessionMs + fiveHoursMs) / 1000)

        let today = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: today)
        let monday = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: today) ?? today
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: monday) ?? today
        let weekStartMs = monday.timeIntervalSince1970 * 1000
        let weekEndMs = weekEnd.timeIntervalSince1970 * 1000

        let month = monthBounds(now: now, anchorMs: anchorMs, calendar: calendar)
        func sum(_ start: Double, _ end: Double) -> Double {
            let value = costs.reduce(0.0) { $0 + (($1.ms >= start && $1.ms < end) ? $1.cost : 0) }
            return (value * 10_000).rounded() / 10_000
        }
        return OpenCodeGoWindows(
            sessionSpend: sum(sessionStart, nowMs), sessionResetsAt: sessionReset,
            weeklySpend: sum(weekStartMs, weekEndMs), weeklyResetsAt: weekEnd,
            monthlySpend: sum(month.start, month.end), monthlyResetsAt: Date(timeIntervalSince1970: month.end / 1000)
        )
    }

    private static func monthBounds(now: Date, anchorMs: Double?, calendar: Calendar) -> (start: Double, end: Double) {
        let nowParts = calendar.dateComponents([.year, .month], from: now)
        guard let anchorMs, anchorMs.isFinite else {
            let start = calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: nowParts.year, month: nowParts.month, day: 1))!
            let end = calendar.date(byAdding: .month, value: 1, to: start)!
            return (start.timeIntervalSince1970 * 1000, end.timeIntervalSince1970 * 1000)
        }
        let anchor = Date(timeIntervalSince1970: anchorMs / 1000)
        let anchorParts = calendar.dateComponents([.day, .hour, .minute, .second, .nanosecond], from: anchor)
        func start(year: Int, month: Int) -> Date {
            let first = calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: year, month: month, day: 1))!
            let days = calendar.range(of: .day, in: .month, for: first)?.count ?? 28
            return calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: year, month: month,
                day: min(anchorParts.day ?? 1, days), hour: anchorParts.hour, minute: anchorParts.minute,
                second: anchorParts.second, nanosecond: anchorParts.nanosecond))!
        }
        var current = start(year: nowParts.year!, month: nowParts.month!)
        if current > now { current = calendar.date(byAdding: .month, value: -1, to: current)! }
        let currentParts = calendar.dateComponents([.year, .month], from: current)
        let nextMonth = calendar.date(byAdding: .month, value: 1, to: calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: currentParts.year, month: currentParts.month, day: 1))!)!
        let nextParts = calendar.dateComponents([.year, .month], from: nextMonth)
        let next = start(year: nextParts.year!, month: nextParts.month!)
        return (current.timeIntervalSince1970 * 1000, next.timeIntervalSince1970 * 1000)
    }
}

struct OpenCodeGoWindows {
    let sessionSpend: Double
    let sessionResetsAt: Date
    let weeklySpend: Double
    let weeklyResetsAt: Date
    let monthlySpend: Double
    let monthlyResetsAt: Date
}
