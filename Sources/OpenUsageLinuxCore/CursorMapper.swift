import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum CursorLinuxMapper {
    private static let monthMs = 2_592_000_000

    public static func map(
        usage: [String: Any],
        planName: String?,
        creditGrants: [String: Any]?,
        stripeBalanceCents: Double,
        accountLabel: String?,
        sandUsage: [String: Any]? = nil,
        usageSummary: [String: Any]? = nil,
        now: Date = Date()
    ) throws -> ProviderUsageSnapshot {
        guard usage["enabled"] as? Bool != false,
              let planUsage = usage["planUsage"] as? [String: Any]
        else { throw CursorLinuxError.noActiveSubscription }
        let limit = cursorMapperNumber(planUsage["limit"])
        let totalPercent = CursorSpendingPools.cursorModelsPercent(planUsage: planUsage)
            ?? cursorMapperNumber(planUsage["totalPercentUsed"])
        guard limit != nil || totalPercent != nil else { throw CursorLinuxError.totalUsageLimitMissing }

        var metrics: [UsageMetric] = []
        appendCredits(grants: creditGrants, stripe: stripeBalanceCents, to: &metrics)
        let usedCents = cursorMapperNumber(planUsage["totalSpend"])
            ?? ((limit ?? 0) - (cursorMapperNumber(planUsage["remaining"]) ?? 0))
        let cycle = billingCycle(usage)
        let spend = usage["spendLimitUsage"] as? [String: Any]
        let normalizedPlan = planName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let isTeam = normalizedPlan == "team"
            || (spend?["limitType"] as? String)?.lowercased() == "team"
            || (cursorMapperNumber(spend?["pooledLimit"]) ?? 0) > 0
        let summaryPlan = CursorSpendingPools.summaryPlan(usageSummary)
        if isTeam {
            guard let limit else {
                throw CursorLinuxError.requestBasedUnavailable("Cursor request-based usage data unavailable. Try again later.")
            }
            metrics.append(UsageMetric(
                kind: .progress,
                label: CursorSpendingPools.totalUsageLabel,
                used: usedCents / 100,
                limit: limit / 100,
                resetsAt: cycle.reset,
                periodDurationMilliseconds: cycle.duration,
                detail: "dollars",
                periodDurationMs: cycle.duration
            ))
        }
        appendSpendingPools(
            planUsage: planUsage,
            summaryPlan: summaryPlan,
            planName: planName,
            computedPercent: isTeam ? nil : (totalPercent ?? (limit.flatMap { $0 > 0 ? usedCents / $0 * 100 : nil } ?? 0)),
            cycle: cycle,
            to: &metrics
        )
        appendGrokBotWeekly(sandUsage, to: &metrics)
        if let spend {
            let spendLimit = cursorMapperNumber(spend["individualLimit"]) ?? cursorMapperNumber(spend["pooledLimit"]) ?? 0
            let remaining = cursorMapperNumber(spend["individualRemaining"]) ?? cursorMapperNumber(spend["pooledRemaining"]) ?? 0
            let reported = [cursorMapperNumber(spend["individualUsed"]), cursorMapperNumber(spend["pooledUsed"]), cursorMapperNumber(spend["totalSpend"])].compactMap { $0 }
            let spent = reported.first(where: { $0 > 0 }) ?? max(0, spendLimit - remaining)
            if spendLimit > 0 {
                metrics.append(UsageMetric(kind: .progress, label: "On-demand", used: spent / 100, limit: spendLimit / 100, detail: "dollars"))
            } else if spent > 0 {
                metrics.append(UsageMetric(kind: .value, label: "On-demand", used: spent / 100, detail: "dollars"))
            }
        }
        return snapshot(plan: cursorMapperTitle(planName), account: accountLabel, metrics: metrics, now: now)
    }

    public static func mapRequestBased(
        summary: [String: Any]?,
        requests: [String: Any]?,
        planName: String?,
        accountLabel: String?,
        sandUsage: [String: Any]? = nil,
        now: Date = Date(),
        unavailableMessage: String = "Cursor request-based usage data unavailable. Try again later."
    ) throws -> ProviderUsageSnapshot {
        let cycle = summaryCycle(summary, requests)
        var metrics: [UsageMetric] = []
        if let bucket = requests?["gpt-4"] as? [String: Any], let limit = cursorMapperNumber(bucket["maxRequestUsage"]), limit > 0 {
            let used = max(0, cursorMapperNumber(bucket["numRequests"]) ?? cursorMapperNumber(bucket["numRequestsTotal"]) ?? 0)
            for label in [CursorSpendingPools.totalUsageLabel, "Requests"] {
                metrics.append(UsageMetric(kind: .progress, label: label, used: used, limit: limit, resetsAt: cycle.reset, detail: "requests"))
            }
        } else {
            appendSummaryTotal(summary, cycle: cycle, to: &metrics)
        }
        appendSpendingPools(
            planUsage: nil,
            summaryPlan: CursorSpendingPools.summaryPlan(summary),
            planName: planName ?? (summary?["membershipType"] as? String),
            computedPercent: nil,
            cycle: cycle,
            to: &metrics
        )
        appendGrokBotWeekly(sandUsage, to: &metrics)
        let individual = summary?["individualUsage"] as? [String: Any]
        let team = summary?["teamUsage"] as? [String: Any]
        if !appendOnDemand(individual?["onDemand"], reset: cycle.reset, to: &metrics) {
            _ = appendOnDemand(team?["onDemand"], reset: cycle.reset, to: &metrics)
        }
        guard !metrics.isEmpty else { throw CursorLinuxError.requestBasedUnavailable(unavailableMessage) }
        return snapshot(plan: cursorMapperTitle(planName) ?? cursorMapperTitle(summary?["membershipType"] as? String), account: accountLabel, metrics: metrics, now: now)
    }

    static func shouldFallback(_ usage: [String: Any], planName: String?, planUnavailable: Bool) -> Bool {
        guard usage["enabled"] as? Bool != false else { return false }
        let planUsage = usage["planUsage"] as? [String: Any]
        let missingLimit = planUsage != nil && cursorMapperNumber(planUsage?["limit"]) == nil
        let unusable = planUsage == nil || missingLimit
        let normalized = planName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let spend = usage["spendLimitUsage"] as? [String: Any]
        let teamShape = (spend?["limitType"] as? String)?.lowercased() == "team" || (cursorMapperNumber(spend?["pooledLimit"]) ?? 0) > 0
        return (unusable && (normalized == "enterprise" || normalized == "team"))
            || (unusable && normalized.isEmpty && planUnavailable
                && CursorSpendingPools.cursorModelsPercent(planUsage: planUsage) == nil)
            || (teamShape && missingLimit)
    }

    private static func snapshot(plan: String?, account: String?, metrics: [UsageMetric], now: Date) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(providerID: "cursor", displayName: "Cursor", accountLabel: account, plan: plan,
                              metrics: metrics, links: CursorLinuxProvider.links, widgets: CursorLinuxProvider.widgets, refreshedAt: now)
    }

    /// Cursor dashboard Grok Bot weekly pool from `GetSandUsageStatus`.
    /// Omit the tile when Cursor leaves the pool off or omits the percent — never invent 0%.
    static func appendGrokBotWeekly(_ raw: [String: Any]?, to metrics: inout [UsageMetric]) {
        guard let metric = grokBotWeeklyMetric(from: raw) else { return }
        metrics.append(metric)
    }

    static func grokBotWeeklyMetric(from raw: [String: Any]?) -> UsageMetric? {
        guard let raw, let percent = cursorMapperPercent(raw["usagePercent"]), percent.isFinite else { return nil }
        if cursorMapperFlag(raw["hasNonZeroIncludedLimit"]) == false { return nil }
        if cursorMapperFlag(raw["includedLimitZero"]) == true { return nil }
        let start = cursorMapperDate(raw["currentPeriodStart"])
        let reset = cursorMapperDate(raw["nextResetTimestampUtc"])
        let entitled = cursorMapperFlag(raw["hasNonZeroIncludedLimit"]) == true || start != nil || reset != nil
        guard entitled else { return nil }
        let period = grokBotWeeklyPeriodMs(start: start, reset: reset)
        return UsageMetric(
            kind: .progress,
            label: "Grok Bot weekly",
            used: percent,
            limit: 100,
            resetsAt: reset,
            periodDurationMilliseconds: period,
            detail: "percent",
            periodDurationMs: period
        )
    }

    private static func grokBotWeeklyPeriodMs(start: Date?, reset: Date?) -> Int {
        if let start, let reset, reset > start {
            return Int((reset.timeIntervalSince(start) * 1000).rounded())
        }
        return 604_800_000
    }

    private static func appendCredits(grants: [String: Any]?, stripe: Double, to metrics: inout [UsageMetric]) {
        let valid = grants?["hasCreditGrants"] as? Bool == true && (cursorMapperNumber(grants?["totalCents"]) ?? 0) > 0
        let total = (valid ? cursorMapperNumber(grants?["totalCents"]) ?? 0 : 0) + stripe
        let used = valid ? cursorMapperNumber(grants?["usedCents"]) ?? 0 : 0
        if total > 0 { metrics.append(UsageMetric(kind: .value, label: "Credits", used: max(0, total - used) / 100, detail: "dollars")) }
    }

    private static func appendSpendingPools(
        planUsage: [String: Any]?,
        summaryPlan: [String: Any]?,
        planName: String?,
        computedPercent: Double?,
        cycle: (reset: Date?, duration: Int),
        to metrics: inout [UsageMetric]
    ) {
        if !metrics.contains(where: { $0.label == CursorSpendingPools.cursorModelsLabel }) {
            let percent = CursorSpendingPools.cursorModelsPercent(planUsage: planUsage, summaryPlan: summaryPlan)
                ?? computedPercent
            if let percent {
                metrics.append(UsageMetric(
                    kind: .progress,
                    label: CursorSpendingPools.cursorModelsLabel,
                    used: percent,
                    limit: 100,
                    resetsAt: cycle.reset,
                    periodDurationMilliseconds: cycle.duration,
                    detail: CursorSpendingPools.cursorModelsDetail,
                    periodDurationMs: cycle.duration
                ))
            }
        }
        if !metrics.contains(where: { $0.label == CursorSpendingPools.otherModelsLabel }),
           let percent = CursorSpendingPools.otherModelsPercent(
            planUsage: planUsage,
            summaryPlan: summaryPlan,
            planName: planName
           )
        {
            metrics.append(UsageMetric(
                kind: .progress,
                label: CursorSpendingPools.otherModelsLabel,
                used: percent,
                limit: 100,
                resetsAt: cycle.reset,
                periodDurationMilliseconds: cycle.duration,
                periodDurationMs: cycle.duration
            ))
        }
    }

    private static func appendSummaryTotal(
        _ summary: [String: Any]?,
        cycle: (reset: Date?, duration: Int),
        to metrics: inout [UsageMetric]
    ) {
        let individual = summary?["individualUsage"] as? [String: Any]
        let team = summary?["teamUsage"] as? [String: Any]
        if (summary?["limitType"] as? String)?.lowercased() == "team",
           appendDollar(team?["pooled"], label: CursorSpendingPools.totalUsageLabel, reset: cycle.reset, to: &metrics)
        { return }
        if CursorSpendingPools.cursorModelsPercent(
            planUsage: nil,
            summaryPlan: individual?["plan"] as? [String: Any]
        ) != nil {
            return
        }
        if appendDollar(individual?["overall"], label: CursorSpendingPools.totalUsageLabel, reset: cycle.reset, to: &metrics) { return }
        _ = appendDollar(team?["pooled"], label: CursorSpendingPools.totalUsageLabel, reset: cycle.reset, to: &metrics)
    }

    private static func appendOnDemand(_ raw: Any?, reset: Date?, to metrics: inout [UsageMetric]) -> Bool {
        guard let bucket = raw as? [String: Any], bucket["enabled"] as? Bool != false else { return false }
        if appendDollar(bucket, label: "On-demand", reset: reset, to: &metrics) { return true }
        if let used = cursorMapperNumber(bucket["used"]), used > 0 {
            metrics.append(UsageMetric(kind: .value, label: "On-demand", used: used / 100, detail: "dollars")); return true
        }
        return false
    }

    private static func appendDollar(_ raw: Any?, label: String, reset: Date?, to metrics: inout [UsageMetric]) -> Bool {
        guard let bucket = raw as? [String: Any], bucket["enabled"] as? Bool != false,
              let limit = cursorMapperNumber(bucket["limit"]), limit > 0 else { return false }
        let inferred = max(0, limit - (cursorMapperNumber(bucket["remaining"]) ?? limit))
        let used = cursorMapperNumber(bucket["used"]).flatMap { $0 > 0 ? $0 : nil } ?? inferred
        metrics.append(UsageMetric(kind: .progress, label: label, used: max(0, used) / 100, limit: limit / 100, resetsAt: reset, detail: "dollars"))
        return true
    }

    private static func billingCycle(_ usage: [String: Any]) -> (reset: Date?, duration: Int) {
        let start = cursorMapperNumber(usage["billingCycleStart"]), end = cursorMapperNumber(usage["billingCycleEnd"])
        guard let end else { return (nil, monthMs) }
        return (Date(timeIntervalSince1970: end / 1000), start.flatMap { end > $0 ? Int(end - $0) : nil } ?? monthMs)
    }

    private static func summaryCycle(_ summary: [String: Any]?, _ requests: [String: Any]?) -> (reset: Date?, duration: Int) {
        let start = cursorMapperISODate(summary?["billingCycleStart"]), end = cursorMapperISODate(summary?["billingCycleEnd"])
        if let start, let end, end > start { return (end, Int(end.timeIntervalSince(start) * 1000)) }
        let requestStart = cursorMapperISODate(requests?["startOfMonth"])
        return (requestStart?.addingTimeInterval(Double(monthMs) / 1000), monthMs)
    }
}

private func cursorMapperNumber(_ value: Any?) -> Double? {
    if value is Bool { return nil }
    if let value = value as? NSNumber { return value.doubleValue }
    if let value = value as? String { return Double(value) }
    return nil
}

/// JSON `0` can bridge as `NSNumber` that `is Bool`, which `cursorMapperNumber` rejects.
/// Grok Bot weekly must keep a real 0% week and still ignore actual JSON booleans.
private func cursorMapperPercent(_ value: Any?) -> Double? {
    if let value, type(of: value) == Bool.self { return nil }
    if let value = value as? NSNumber { return value.doubleValue }
    if let value = value as? Double { return value }
    if let value = value as? Int { return Double(value) }
    if let value = value as? String { return Double(value) }
    return cursorMapperNumber(value)
}

private func cursorMapperFlag(_ value: Any?) -> Bool? {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    return nil
}

private func cursorMapperISODate(_ value: Any?) -> Date? {
    cursorMapperDate(value)
}

private func cursorMapperDate(_ value: Any?) -> Date? {
    if let raw = value as? String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let millis = Double(trimmed), millis > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: millis / 1000)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: trimmed) ?? ISO8601DateFormatter().date(from: trimmed)
    }
    if let millis = cursorMapperNumber(value), millis > 1_000_000_000_000 {
        return Date(timeIntervalSince1970: millis / 1000)
    }
    return nil
}

private func cursorMapperTitle(_ value: String?) -> String? {
    guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
    return raw.split(whereSeparator: { $0.isWhitespace || $0 == "_" || $0 == "-" }).map { word in
        word.prefix(1).uppercased() + word.dropFirst().lowercased()
    }.joined(separator: " ")
}
