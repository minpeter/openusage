import Foundation
/// The same anonymous event names and stable property vocabulary used by the macOS telemetry recorder.
public enum LinuxAnalyticsEvent {
    public static let dailyActive = "app_daily_active"
    public static let providerRefreshDaily = "provider_refresh_daily"
}

public enum LinuxAnalyticsMenuBarStyle: String, Codable, Sendable {
    case text
    case bars
}

public enum LinuxAnalyticsErrorCategory: String, Codable, CaseIterable, Sendable {
    case notLoggedIn = "not_logged_in"
    case authExpired = "auth_expired"
    case authInvalid = "auth_invalid"
    case credentialAccess = "credential_access"
    case network
    case decoding
    case http4xx = "http_4xx"
    case http5xx = "http_5xx"
    case rateLimited = "rate_limited"
    case notAvailable = "not_available"
    case other
}

/// Typed input deliberately has no account, token, error-message, usage-value, or path fields.
public struct LinuxAnalyticsDailySnapshot: Sendable {
    public let enabledProviders: [String]
    public let enabledMetricIDs: [String]
    public let pinnedMetricIDs: [String]
    public let expandedMetricIDs: [String]
    public let menuBarStyle: LinuxAnalyticsMenuBarStyle

    public init(
        enabledProviders: [String],
        enabledMetricIDs: [String],
        pinnedMetricIDs: [String],
        expandedMetricIDs: [String],
        menuBarStyle: LinuxAnalyticsMenuBarStyle
    ) {
        self.enabledProviders = enabledProviders
        self.enabledMetricIDs = enabledMetricIDs
        self.pinnedMetricIDs = pinnedMetricIDs
        self.expandedMetricIDs = expandedMetricIDs
        self.menuBarStyle = menuBarStyle
    }
}

/// One already-aggregated provider/day summary. Raw errors and usage values cannot enter this type.
public struct LinuxAnalyticsProviderRollup: Sendable {
    public let providerID: String
    public let successCount: Int
    public let failureCount: Int
    public let errorCounts: [LinuxAnalyticsErrorCategory: Int]
    public let manualRefreshCount: Int

    public init(
        providerID: String,
        successCount: Int,
        failureCount: Int,
        errorCounts: [LinuxAnalyticsErrorCategory: Int],
        manualRefreshCount: Int
    ) {
        self.providerID = providerID
        self.successCount = successCount
        self.failureCount = failureCount
        self.errorCounts = errorCounts
        self.manualRefreshCount = manualRefreshCount
    }
}

public struct LinuxAnalyticsConfiguration: Sendable {
    public let projectToken: String
    public let endpoint: URL
    public let appVersion: String
    public let osVersion: String

    public init(
        projectToken: String = "phc_vGEqXEpQNwViyKnMNWvmKWpv8XxMT3yaeYi6gfidr4nf",
        endpoint: URL = URL(string: "https://us.i.posthog.com/capture/")!,
        appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
        osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString
    ) {
        self.projectToken = projectToken
        self.endpoint = endpoint
        self.appVersion = appVersion
        self.osVersion = osVersion
    }
}

public enum LinuxAnalyticsDelivery: Equatable, Sendable {
    case sent
    case disabled
    case invalidInput
    case payloadTooLarge
    case transportFailure
    case rejected(statusCode: Int)
}

/// Plain XDG identity storage. This is intentionally not Secret Service: the random UUID is not a
/// credential and keeping it independent prevents account or token material from entering analytics.
public struct LinuxAnalyticsIdentityStore: Sendable {
    public let fileURL: URL
    private let makeUUID: @Sendable () -> UUID

    public init(
        paths: LinuxPaths = LinuxPaths(),
        makeUUID: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.init(
            fileURL: paths.configDirectory.appendingPathComponent("analytics-install-id"),
            makeUUID: makeUUID
        )
    }

    public init(
        fileURL: URL,
        makeUUID: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.fileURL = fileURL
        self.makeUUID = makeUUID
    }

    public func installID() throws -> String {
        if let data = try? Data(contentsOf: fileURL), data.count <= 128,
           let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let uuid = UUID(uuidString: value) {
            return uuid.uuidString
        }

        let value = makeUUID().uuidString
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data((value + "\n").utf8).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        return value
    }
}

/// Single-attempt PostHog delivery. There is no queue, persistence, retry, or background flush: a
/// failed request is returned to the caller and discarded, so failures cannot accumulate on disk.
