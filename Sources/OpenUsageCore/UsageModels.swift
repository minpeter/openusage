import Foundation

public struct UsageMetric: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case progress
        case value
        case values
        case badge
        case chart
        case text
    }

    public let kind: Kind
    public let label: String
    public let used: Double
    public let limit: Double?
    public let resetsAt: Date?
    public let periodDurationMilliseconds: Int?
    public let detail: String?
    public let values: [UsageValue]?
    public let points: [UsagePoint]?
    public let text: String?
    public let periodDurationMs: Int?
    public let expiriesAt: [Date]?

    public init(
        kind: Kind,
        label: String,
        used: Double,
        limit: Double? = nil,
        resetsAt: Date? = nil,
        periodDurationMilliseconds: Int? = nil,
        detail: String? = nil,
        values: [UsageValue]? = nil,
        points: [UsagePoint]? = nil,
        text: String? = nil,
        periodDurationMs: Int? = nil,
        expiriesAt: [Date]? = nil
    ) {
        self.kind = kind
        self.label = label
        self.used = used
        self.limit = limit
        self.resetsAt = resetsAt
        self.periodDurationMilliseconds = periodDurationMilliseconds
        self.detail = detail
        self.values = values
        self.points = points
        self.text = text
        self.periodDurationMs = periodDurationMs
        self.expiriesAt = expiriesAt
    }

    public var fraction: Double? {
        guard let limit, limit > 0 else { return nil }
        return min(max(used / limit, 0), 1)
    }
}

public struct UsageValue: Codable, Equatable, Sendable {
    public enum Unit: String, Codable, Sendable {
        case count
        case credits
        case dollars
        case percent
        case tokens
    }

    public let label: String
    public let value: Double
    public let unit: Unit

    public init(label: String, value: Double, unit: Unit) {
        self.label = label
        self.value = value
        self.unit = unit
    }
}

public struct UsagePoint: Codable, Equatable, Sendable {
    public let date: Date
    public let value: Double

    public init(date: Date, value: Double) {
        self.date = date
        self.value = value
    }
}

public struct ProviderLink: Codable, Equatable, Sendable {
    public let label: String
    public let url: String

    public init(label: String, url: String) {
        self.label = label
        self.url = url
    }

    public var safeURL: URL? {
        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanLabel.isEmpty,
              let parsed = URL(string: cleanURL),
              parsed.scheme == "https" || parsed.scheme == "http"
        else {
            return nil
        }
        return parsed
    }

    /// Short host for link-row subtitles (`status.cursor.com`), never the raw URL.
    public var displayHost: String? {
        guard let host = safeURL?.host, !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

public struct WidgetDescriptor: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let metricLabel: String

    public init(id: String, title: String, metricLabel: String) {
        self.id = id
        self.title = title
        self.metricLabel = metricLabel
    }
}

public struct ProviderUsageSnapshot: Codable, Equatable, Sendable {
    public let providerID: String
    public let instanceID: String
    public let displayName: String
    public let accountLabel: String?
    public let plan: String?
    public let metrics: [UsageMetric]
    public let links: [ProviderLink]
    public let widgets: [WidgetDescriptor]
    public let refreshedAt: Date
    public let errorMessage: String?
    public let warning: String?

    public init(
        providerID: String,
        instanceID: String? = nil,
        displayName: String,
        accountLabel: String? = nil,
        plan: String?,
        metrics: [UsageMetric],
        links: [ProviderLink] = [],
        widgets: [WidgetDescriptor] = [],
        refreshedAt: Date = Date(),
        errorMessage: String? = nil,
        warning: String? = nil
    ) {
        self.providerID = providerID
        self.instanceID = instanceID ?? providerID
        self.displayName = displayName
        self.accountLabel = accountLabel
        self.plan = plan
        self.metrics = metrics
        self.links = links
        self.widgets = widgets
        self.refreshedAt = refreshedAt
        self.errorMessage = errorMessage
        self.warning = warning
    }

    public static func error(
        providerID: String,
        displayName: String,
        message: String,
        refreshedAt: Date = Date()
    ) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            providerID: providerID,
            instanceID: providerID,
            displayName: displayName,
            accountLabel: nil,
            plan: nil,
            metrics: [],
            links: [],
            widgets: [],
            refreshedAt: refreshedAt,
            errorMessage: message
        )
    }

    private enum CodingKeys: String, CodingKey {
        case providerID
        case instanceID
        case displayName
        case accountLabel
        case plan
        case metrics
        case links
        case widgets
        case refreshedAt
        case errorMessage
        case warning
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try values.decode(String.self, forKey: .providerID)
        instanceID = try values.decodeIfPresent(String.self, forKey: .instanceID) ?? providerID
        displayName = try values.decode(String.self, forKey: .displayName)
        accountLabel = try values.decodeIfPresent(String.self, forKey: .accountLabel)
        plan = try values.decodeIfPresent(String.self, forKey: .plan)
        metrics = try values.decode([UsageMetric].self, forKey: .metrics)
        links = try values.decodeIfPresent([ProviderLink].self, forKey: .links) ?? []
        widgets = try values.decodeIfPresent([WidgetDescriptor].self, forKey: .widgets) ?? []
        refreshedAt = try values.decode(Date.self, forKey: .refreshedAt)
        errorMessage = try values.decodeIfPresent(String.self, forKey: .errorMessage)
        warning = try values.decodeIfPresent(String.self, forKey: .warning)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(providerID, forKey: .providerID)
        try values.encode(instanceID, forKey: .instanceID)
        try values.encode(displayName, forKey: .displayName)
        try values.encodeIfPresent(accountLabel, forKey: .accountLabel)
        try values.encodeIfPresent(plan, forKey: .plan)
        try values.encode(metrics, forKey: .metrics)
        try values.encode(links, forKey: .links)
        try values.encode(widgets, forKey: .widgets)
        try values.encode(refreshedAt, forKey: .refreshedAt)
        try values.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try values.encodeIfPresent(warning, forKey: .warning)
    }
}

public enum LinuxUsageError: Error, LocalizedError, Equatable {
    case credentialsMissing(String)
    case invalidCredentials(String)
    case invalidResponse(String)
    case requestFailed(provider: String, statusCode: Int)

    public var errorDescription: String? {
        switch self {
        case .credentialsMissing(let provider):
            "\(provider) credentials were not found."
        case .invalidCredentials(let provider):
            "\(provider) credentials could not be read."
        case .invalidResponse(let provider):
            "\(provider) returned an invalid usage response."
        case .requestFailed(let provider, let statusCode):
            "\(provider) usage request failed with HTTP \(statusCode)."
        }
    }
}
