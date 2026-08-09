import Foundation

public enum ClaudeUsageMapper {
    public static let sessionPeriodMs = 18_000_000
    public static let weeklyPeriodMs = 604_800_000

    public static func map(
        data: Data,
        accountLabel: String? = nil,
        credentials: ClaudeCredentials,
        now: Date = Date()
    ) throws -> ProviderUsageSnapshot {
        let snapshot = try map(response: ProviderHTTPResponse(statusCode: 200, body: data), accountLabel: accountLabel,
                               credentials: credentials, now: now)
        // Compatibility for the first Linux dashboard contract; provider clients use the response-based
        // parity API and its macOS metric label (`Extra usage spent`).
        let metrics = snapshot.metrics.map { metric -> UsageMetric in
            guard metric.label == "Extra usage spent" else { return metric }
            return UsageMetric(kind: metric.kind, label: "Extra Usage", used: metric.used, limit: metric.limit,
                resetsAt: metric.resetsAt, detail: metric.detail, values: metric.values, points: metric.points,
                text: metric.text, periodDurationMs: metric.periodDurationMs, expiriesAt: metric.expiriesAt)
        }
        return ProviderUsageSnapshot(providerID: snapshot.providerID, instanceID: snapshot.instanceID,
            displayName: snapshot.displayName, accountLabel: snapshot.accountLabel, plan: snapshot.plan,
            metrics: metrics, links: snapshot.links, widgets: snapshot.widgets, refreshedAt: snapshot.refreshedAt,
            errorMessage: snapshot.errorMessage, warning: snapshot.warning)
    }

    public static func map(
        response: ProviderHTTPResponse,
        instanceID: String = "claude",
        displayName: String = "Claude",
        accountLabel: String? = nil,
        credentials: ClaudeCredentials,
        now: Date = Date()
    ) throws -> ProviderUsageSnapshot {
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 { throw ClaudeProviderError.tokenExpired }
            throw ClaudeProviderError.requestFailed(response.statusCode)
        }
        guard let root = parityJSON(response.body) else { throw ClaudeProviderError.invalidResponse }
        var metrics: [UsageMetric] = []
        appendWindow(root["five_hour"], label: "Session", period: sessionPeriodMs, to: &metrics)
        appendWindow(root["seven_day"], label: "Weekly", period: weeklyPeriodMs, to: &metrics)
        appendWindow(root["seven_day_sonnet"], label: "Sonnet", period: weeklyPeriodMs, to: &metrics)
        if let limits = root["limits"] as? [Any] {
            for entry in limits {
                guard let limit = entry as? [String: Any], limit["kind"] as? String == "weekly_scoped",
                      let scope = limit["scope"] as? [String: Any],
                      let model = scope["model"] as? [String: Any], model["display_name"] as? String == "Fable",
                      let used = parityNumber(limit["percent"]) else { continue }
                metrics.append(progress("Fable", used, limit, weeklyPeriodMs)); break
            }
        }
        if let extra = root["extra_usage"] as? [String: Any], extra["is_enabled"] as? Bool == true,
           let cents = parityNumber(extra["used_credits"]) {
            let used = cents / 100
            if let cap = parityNumber(extra["monthly_limit"]), cap > 0 {
                metrics.append(UsageMetric(kind: .progress, label: "Extra usage spent", used: used, limit: cap / 100))
            } else if used > 0 {
                metrics.append(UsageMetric(kind: .values, label: "Extra usage spent", used: used,
                    values: [UsageValue(label: "", value: used, unit: .dollars)]))
            }
        }
        return ProviderUsageSnapshot(
            providerID: "claude", instanceID: instanceID, displayName: displayName,
            accountLabel: accountLabel, plan: formatPlan(credentials), metrics: metrics,
            links: ProviderDefinitions.claudeLinks,
            widgets: ProviderDefinitions.claudeWidgets(instanceID: instanceID), refreshedAt: now
        )
    }

    public static func rateLimited(credentials: ClaudeCredentials, retryAfterSeconds: Int?, now: Date = Date()) -> ProviderUsageSnapshot {
        let wait = retryAfterSeconds.map { $0 > 0 ? "~\(Int(ceil(Double($0) / 60)))m" : "now" }
        let status = wait.map { "Rate limited, retry in \($0)" } ?? "Rate limited, try again later"
        let warning = "Updates blocked by Anthropic. Be patient — manual refreshes will make it worse."
            + (wait.map { " Retrying in \($0)." } ?? "")
        return ProviderUsageSnapshot(providerID: "claude", displayName: "Claude", plan: formatPlan(credentials), metrics: [
            UsageMetric(kind: .badge, label: "Status", used: 0, text: status),
            UsageMetric(kind: .text, label: "Note", used: 0, text: "Live usage rate limited - data may be stale"),
        ], links: ProviderDefinitions.claudeLinks, widgets: ProviderDefinitions.claudeWidgets(instanceID: "claude"),
        refreshedAt: now, warning: warning)
    }

    private static func appendWindow(_ value: Any?, label: String, period: Int, to metrics: inout [UsageMetric]) {
        guard let window = value as? [String: Any], let used = parityNumber(window["utilization"]) else { return }
        metrics.append(progress(label, used, window, period))
    }

    private static func progress(_ label: String, _ used: Double, _ window: [String: Any], _ period: Int) -> UsageMetric {
        UsageMetric(kind: .progress, label: label, used: used, limit: 100,
                    resetsAt: parityDate(window["resets_at"]), periodDurationMs: period)
    }

    private static func formatPlan(_ credentials: ClaudeCredentials) -> String? {
        guard let raw = credentials.subscriptionType?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let base = raw.split(separator: " ").map { $0.lowercased().capitalized }.joined(separator: " ")
        guard let tier = credentials.rateLimitTier,
              let range = tier.range(of: #"\d+x"#, options: .regularExpression) else { return base }
        return "\(base) \(tier[range])"
    }
}

public enum CodexUsageMapper {
    public static let sessionPeriodMs = 18_000_000
    public static let weeklyPeriodMs = 604_800_000
    public static let creditUSDRate = 0.04

    public static func map(data: Data, accountLabel: String? = nil, now: Date = Date()) throws -> ProviderUsageSnapshot {
        try map(response: ProviderHTTPResponse(statusCode: 200, body: data), accountLabel: accountLabel, now: now)
    }

    public static func map(
        response: ProviderHTTPResponse,
        resetCredits: ProviderHTTPResponse? = nil,
        accountLabel: String? = nil,
        now: Date = Date()
    ) throws -> ProviderUsageSnapshot {
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 { throw CodexProviderError.tokenExpired }
            throw CodexProviderError.requestFailed(response.statusCode)
        }
        guard let root = parityJSON(response.body) else { throw CodexProviderError.invalidResponse }
        var metrics = classified(
            root["rate_limit"] as? [String: Any], labels: ("Session", "Weekly"), now: now,
            headerValues: (parityNumber(response.header("x-codex-primary-used-percent")),
                           parityNumber(response.header("x-codex-secondary-used-percent")))
        )
        if let entries = root["additional_rate_limits"] as? [Any],
           let spark = entries.compactMap({ $0 as? [String: Any] }).first(where: {
               [$0["limit_name"], $0["metered_feature"]].compactMap { $0 as? String }.contains { $0.lowercased().contains("spark") }
           }) {
            metrics += classified(spark["rate_limit"] as? [String: Any], labels: ("Spark", "Spark Weekly"), now: now)
        }
        let dedicated = resetCredits.flatMap { response -> [String: Any]? in
            guard (200..<300).contains(response.statusCode), let body = parityJSON(response.body),
                  parityNumber(body["available_count"]) != nil else { return nil }
            return body
        }
        if let source = dedicated ?? root["rate_limit_reset_credits"] as? [String: Any],
           let count = parityNumber(source["available_count"]), count >= 0 {
            let expiries = (source["credits"] as? [[String: Any]] ?? []).filter {
                ($0["status"] as? String).map { $0 == "available" } ?? true
            }.compactMap { parityDate($0["expires_at"]) }.sorted()
            metrics.append(UsageMetric(kind: .values, label: "Rate Limit Resets", used: floor(count),
                values: [UsageValue(label: "available", value: floor(count), unit: .count)], expiriesAt: expiries))
        }
        let credit: Double? = {
            if let credits = root["credits"] as? [String: Any] {
                if let value = parityNumber(credits["balance"]) { return value }
                if credits["has_credits"] as? Bool == false { return 0 }
            }
            return parityNumber(response.header("x-codex-credits-balance"))
        }()
        if let credit {
            let count = max(0, floor(credit))
            metrics.append(UsageMetric(kind: .values, label: "Credits", used: count * creditUSDRate,
                detail: "\(Int(count)) credits", values: [
                    UsageValue(label: "", value: count * creditUSDRate, unit: .dollars),
                    UsageValue(label: "credits", value: count, unit: .count),
                ]))
        }
        return ProviderUsageSnapshot(providerID: "codex", displayName: "Codex", accountLabel: accountLabel,
            plan: plan(root["plan_type"] as? String), metrics: metrics, links: ProviderDefinitions.codexLinks,
            widgets: ProviderDefinitions.codexWidgets, refreshedAt: now)
    }

    private enum WindowKind { case session, weekly }
    private struct Candidate { let object: [String: Any]; let used: Double?; let fallback: WindowKind }

    private static func classified(_ rate: [String: Any]?, labels: (String, String), now: Date,
                                   headerValues: (Double?, Double?) = (nil, nil)) -> [UsageMetric] {
        let values: [(String, Double?, WindowKind)] = [
            ("primary_window", headerValues.0, .session), ("secondary_window", headerValues.1, .weekly),
        ]
        let candidates = values.compactMap { key, header, fallback -> Candidate? in
            guard let object = rate?[key] as? [String: Any] ?? (header == nil ? nil : [:]) else { return nil }
            return Candidate(object: object, used: parityNumber(object["used_percent"]) ?? header, fallback: fallback)
        }
        return [(WindowKind.session, labels.0, sessionPeriodMs), (.weekly, labels.1, weeklyPeriodMs)].compactMap { kind, label, defaultPeriod in
            let selected = candidates.first { exactKind($0.object) == kind }
                ?? candidates.first { exactKind($0.object) == nil && $0.fallback == kind }
            guard let selected, let used = selected.used else { return nil }
            let period = periodMs(selected.object) ?? defaultPeriod
            let resetsAt = parityNumber(selected.object["reset_at"]).map(Date.init(timeIntervalSince1970:))
                ?? parityNumber(selected.object["reset_after_seconds"]).map(now.addingTimeInterval)
            return UsageMetric(kind: .progress, label: label, used: used, limit: 100,
                               resetsAt: resetsAt, periodDurationMs: period)
        }
    }

    private static func periodMs(_ window: [String: Any]) -> Int? {
        parityNumber(window["limit_window_seconds"]).map { Int($0 * 1000) }
    }
    private static func exactKind(_ window: [String: Any]) -> WindowKind? {
        switch periodMs(window) {
        case sessionPeriodMs: return .session
        case weeklyPeriodMs: return .weekly
        default: return nil
        }
    }
    private static func plan(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "prolite": return "Pro 5x"
        case "pro": return "Pro 20x"
        default: return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
