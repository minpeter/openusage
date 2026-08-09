import Foundation

struct UsageWireSnapshot: Encodable {
    let providerId: String
    let instanceId: String
    let displayName: String
    let accountLabel: String?
    let plan: String?
    let lines: [UsageWireLine]
    let links: [ProviderLink]
    let widgets: [WidgetDescriptor]
    let fetchedAt: String
    let error: String?
    let warning: String?

    init(_ snapshot: ProviderUsageSnapshot) {
        providerId = snapshot.providerID
        instanceId = snapshot.instanceID
        displayName = snapshot.displayName
        accountLabel = snapshot.accountLabel
        plan = snapshot.plan
        lines = snapshot.metrics.map(UsageWireLine.init)
        links = snapshot.links
        widgets = snapshot.widgets
        fetchedAt = iso8601(snapshot.refreshedAt)
        error = snapshot.errorMessage
        warning = snapshot.warning
    }
}

struct UsageWireLine: Encodable {
    let type: String
    let kind: String
    let label: String
    let used: Double
    let limit: Double?
    let resetsAt: String?
    let periodDurationMs: Int?
    let detail: String?
    let values: [UsageValue]?
    let points: [UsageWirePoint]?
    let text: String?
    let value: String?
    let format: UsageWireFormat?
    let expiriesAt: [String]?

    init(_ metric: UsageMetric) {
        // `.values` remains a legacy `text` line for existing macOS API consumers. `kind` and the
        // typed `values` array retain the complete Linux metric instead of flattening it away.
        type = switch metric.kind {
        case .chart: "barChart"
        case .values: "text"
        default: metric.kind.rawValue
        }
        kind = metric.kind.rawValue
        label = metric.label
        used = metric.used
        limit = metric.limit
        resetsAt = metric.resetsAt.map(iso8601)
        periodDurationMs = metric.periodDurationMilliseconds ?? metric.periodDurationMs
        detail = metric.detail
        values = metric.values
        points = metric.points?.map(UsageWirePoint.init)
        text = metric.text
        value = metric.kind == .values ? Self.legacyValue(metric.values ?? [])
            : (metric.kind == .text ? metric.text : nil)
        format = metric.kind == .progress ? UsageWireFormat(metric) : nil
        expiriesAt = metric.expiriesAt?.map(iso8601)
    }

    private static func legacyValue(_ values: [UsageValue]) -> String {
        values.map { value in
            let number = value.value.formatted(.number.grouping(.never).precision(.fractionLength(0...2)))
            return switch value.unit {
            case .dollars: "$\(number)"
            case .percent: "\(number)%"
            case .tokens: "\(number) tokens"
            case .credits: "\(number) credits"
            case .count: value.label.isEmpty ? number : "\(number) \(value.label)"
            }
        }.joined(separator: " · ")
    }
}

struct UsageWireFormat: Encodable {
    let kind: String
    let suffix: String?

    init(_ metric: UsageMetric) {
        let lowercased = metric.label.lowercased()
        if metric.limit == 100 {
            kind = "percent"
            suffix = nil
        } else if lowercased.contains("spend") || lowercased.contains("usage") && metric.detail?.contains("$") == true {
            kind = "dollars"
            suffix = nil
        } else {
            kind = "count"
            suffix = metric.detail
        }
    }
}

struct UsageWirePoint: Encodable {
    let date: String
    let value: Double

    init(_ point: UsagePoint) {
        date = iso8601(point.date)
        value = point.value
    }
}
