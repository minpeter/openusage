import Foundation

struct LimitsWireEnvelope: Encodable {
    let schema: String
    let generatedAt: String
    let providers: [String: LimitsWireProvider]
    let errors: [LimitsWireError]
}

struct LimitsWireError: Encodable {
    let providerId: String
    let message: String

    init(providerID: String, message: String) {
        providerId = providerID
        self.message = message
    }
}

struct LimitsWireProvider: Encodable {
    let providerId: String
    let instanceId: String
    let displayName: String
    let accountLabel: String?
    let plan: String?
    let fetchedAt: String
    let expiresAt: String
    let stale: Bool
    let resources: [String: LimitsWireResource]

    init(snapshot: ProviderUsageSnapshot, generatedAt: Date) {
        providerId = snapshot.providerID
        instanceId = snapshot.instanceID
        displayName = snapshot.displayName
        accountLabel = snapshot.accountLabel
        plan = snapshot.plan
        fetchedAt = iso8601(snapshot.refreshedAt)
        let expiry = snapshot.refreshedAt.addingTimeInterval(LinuxUsageAPI.cacheLifetime)
        expiresAt = iso8601(expiry)
        stale = generatedAt >= expiry
        var mapped: [String: LimitsWireResource] = [:]
        for widget in snapshot.widgets {
            guard let metric = snapshot.metrics.first(where: { $0.label == widget.metricLabel }),
                  let resource = LimitsWireResource(metric) else { continue }
            let prefix = snapshot.instanceID + "."
            let key = widget.id.hasPrefix(prefix) ? String(widget.id.dropFirst(prefix.count)) : widget.id
            mapped[key] = resource
        }
        resources = mapped
    }
}

struct LimitsWireResource: Encodable {
    let kind: String
    let unit: String
    let used: Double?
    let available: Double?
    let limit: Double?
    let remaining: Double?
    let utilization: Double?
    let resetsAt: String?
    let windowSeconds: Double?
    let expiresAt: [String]?

    init?(_ metric: UsageMetric) {
        if metric.kind == .progress {
            kind = "consumption"
            unit = metric.limit == 100 ? "percent" : "count"
            used = metric.used
            available = nil
            limit = metric.limit
            remaining = metric.limit.map { max(0, $0 - metric.used) }
            utilization = metric.limit.flatMap { $0 > 0 ? metric.used / $0 : nil }
        } else if let value = metric.values?.first {
            kind = "balance"
            unit = value.unit == .dollars ? "usd" : value.unit.rawValue
            used = nil
            available = value.value
            limit = nil
            remaining = nil
            utilization = nil
        } else if metric.kind == .value {
            kind = "consumption"
            unit = "count"
            used = metric.used
            available = nil
            limit = metric.limit
            remaining = metric.limit.map { max(0, $0 - metric.used) }
            utilization = metric.limit.flatMap { $0 > 0 ? metric.used / $0 : nil }
        } else {
            return nil
        }
        resetsAt = metric.resetsAt.map(iso8601)
        let duration = metric.periodDurationMilliseconds ?? metric.periodDurationMs
        windowSeconds = duration.map { Double($0) / 1_000 }
        expiresAt = metric.expiriesAt?.map(iso8601)
    }
}
