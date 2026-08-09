import Foundation

public enum AntigravityLinuxUsageMapper {
    private static let buckets: [(String, String)] = [
        ("gemini-5h", "Session"), ("gemini-weekly", "Weekly"),
        ("3p-5h", "Claude"), ("3p-weekly", "Claude Weekly"),
    ]
    private static let blacklist: Set<String> = [
        "MODEL_CHAT_20706", "MODEL_CHAT_23310", "MODEL_GOOGLE_GEMINI_2_5_FLASH",
        "MODEL_GOOGLE_GEMINI_2_5_FLASH_THINKING", "MODEL_GOOGLE_GEMINI_2_5_FLASH_LITE",
        "MODEL_GOOGLE_GEMINI_2_5_PRO", "MODEL_PLACEHOLDER_M19", "MODEL_PLACEHOLDER_M9", "MODEL_PLACEHOLDER_M12",
    ]

    public static func metrics(from data: Data) -> [UsageMetric]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let body = (root["response"] as? [String: Any]) ?? root
        if let groups = body["groups"] as? [Any] {
            var found: [String: UsageMetric] = [:]
            for group in groups.compactMap({ $0 as? [String: Any] }) {
                for bucket in (group["buckets"] as? [Any] ?? []).compactMap({ $0 as? [String: Any] }) {
                    guard let id = bucket["bucketId"] as? String,
                          buckets.contains(where: { $0.0 == id }), found[id] == nil,
                          let remaining = finiteNumber(bucket["remainingFraction"]) else { continue }
                    let label = buckets.first(where: { $0.0 == id })!.1
                    found[id] = progress(label: label, remaining: remaining, reset: bucket["resetTime"] as? String)
                }
            }
            return buckets.compactMap { found[$0.0] }
        }
        guard let models = root["models"] as? [String: Any] else { return nil }
        var pools: [String: (remaining: Double, reset: String?)] = [:]
        for (key, value) in models {
            guard let model = value as? [String: Any], model["isInternal"] as? Bool != true else { continue }
            let id = (model["model"] as? String) ?? key
            guard !blacklist.contains(id),
                  let label = ((model["displayName"] as? String) ?? (model["label"] as? String))?.antigravityTrimmedNonEmpty else { continue }
            let quota = model["quotaInfo"] as? [String: Any]
            let remaining = finiteNumber(quota?["remainingFraction"]) ?? 0
            let pool = label.lowercased().contains("gemini") ? "Session" : "Claude"
            if pools[pool] == nil || remaining < pools[pool]!.remaining {
                pools[pool] = (remaining, quota?["resetTime"] as? String)
            }
        }
        return ["Session", "Claude"].compactMap { label in
            pools[label].map { progress(label: label, remaining: $0.remaining, reset: $0.reset) }
        }
    }

    public static func plan(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let paid = (root["paidTier"] as? [String: Any])?["name"] as? String
        let current = (root["currentTier"] as? [String: Any])?["name"] as? String
        return formatPlan(paid ?? current)
    }

    public static func formatPlan(_ raw: String?) -> String? {
        guard let value = raw?.antigravityTrimmedNonEmpty else { return nil }
        if value.hasPrefix("Google AI ") { return String(value.dropFirst("Google AI ".count)).capitalized }
        for name in ["Ultra", "Pro", "Free"] where value.range(of: name, options: .caseInsensitive) != nil { return name }
        return value.split(whereSeparator: \.isWhitespace).map(\.capitalized).joined(separator: " ")
    }

    static func isoDate(_ value: String) -> Date? { ISO8601DateFormatter().date(from: value) }

    private static func progress(label: String, remaining: Double, reset: String?) -> UsageMetric {
        UsageMetric(kind: .progress, label: label, used: ((1 - min(max(remaining, 0), 1)) * 100).rounded(), limit: 100,
                    resetsAt: reset.flatMap(isoDate))
    }

    private static func finiteNumber(_ value: Any?) -> Double? {
        let number: Double?
        if let value = value as? Double { number = value }
        else if let value = value as? Int { number = Double(value) }
        else if let value = value as? NSNumber { number = value.doubleValue }
        else { number = nil }
        return number?.isFinite == true ? number : nil
    }
}
