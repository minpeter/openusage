import Foundation

/// User-facing duration copy for quota windows. Linux mappers and the GTK
/// layer share this so a raw millisecond count never reaches the UI.
public enum LinuxDurationFormat {
    private static let millisecondPeriodSuffix = " ms period"
    private static let hourMilliseconds = 60 * 60 * 1_000
    private static let dayMilliseconds = 24 * hourMilliseconds
    private static let weekMilliseconds = 7 * dayMilliseconds

    public static func period(milliseconds: Int) -> String {
        let duration = max(((milliseconds + 500) / 1_000) * 1_000, 0)
        if duration == weekMilliseconds { return "1 week" }
        if duration == 30 * dayMilliseconds { return "30 days" }
        if duration == dayMilliseconds { return "1 day" }
        if duration == 5 * hourMilliseconds { return "5 hours" }

        if duration >= dayMilliseconds, duration % dayMilliseconds == 0 {
            let days = duration / dayMilliseconds
            return days == 1 ? "1 day" : "\(days) days"
        }
        if duration >= hourMilliseconds, duration % hourMilliseconds == 0 {
            let hours = duration / hourMilliseconds
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        if duration >= 60_000, duration % 60_000 == 0 {
            let minutes = duration / 60_000
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
        return duration == 1 ? "1 millisecond" : "\(duration) milliseconds"
    }

    private static let hiddenUnitTokens: Set<String> = [
        "percent", "dollars", "requests", "credits", "searches", "tokens", "count",
    ]

    /// Replaces a leftover `"<n> ms period"` payload with human-readable copy.
    /// Raw unit enum names (`percent`, `dollars`) and color hex payloads stay hidden.
    public static func displayDetail(_ detail: String?) -> String? {
        guard let detail, !detail.isEmpty else { return nil }
        if let milliseconds = rawMillisecondPeriod(detail) {
            return period(milliseconds: milliseconds)
        }
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if hiddenUnitTokens.contains(trimmed.lowercased()) { return nil }
        if isColorHex(trimmed) { return nil }
        return detail
    }

    private static func isColorHex(_ detail: String) -> Bool {
        guard detail.hasPrefix("#") else { return false }
        let hex = detail.dropFirst()
        return (hex.count == 3 || hex.count == 6) && hex.allSatisfy(\.isHexDigit)
    }

    public static func containsRawMillisecondPeriod(_ text: String) -> Bool {
        rawMillisecondPeriod(text) != nil || text.contains(millisecondPeriodSuffix)
    }

    private static func rawMillisecondPeriod(_ detail: String) -> Int? {
        guard detail.hasSuffix(millisecondPeriodSuffix) else { return nil }
        let number = detail.dropLast(millisecondPeriodSuffix.count)
        guard let milliseconds = Int(number), milliseconds >= 0 else { return nil }
        return milliseconds
    }
}
