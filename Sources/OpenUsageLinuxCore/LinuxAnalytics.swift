import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public actor LinuxAnalyticsClient {
    public static let maximumPayloadBytes = 16 * 1024
    public static let maximumCount = 1_000_000
    public static let maximumIdentifiersPerProperty = 32

    private var enabled: Bool
    private let identityStore: LinuxAnalyticsIdentityStore
    private let transport: any HTTPTransport
    private let configuration: LinuxAnalyticsConfiguration

    public init(
        enabled: Bool,
        identityStore: LinuxAnalyticsIdentityStore = LinuxAnalyticsIdentityStore(),
        transport: any HTTPTransport = URLSessionTransport(maximumResponseBytes: 64 * 1024),
        configuration: LinuxAnalyticsConfiguration = LinuxAnalyticsConfiguration()
    ) {
        self.enabled = enabled
        self.identityStore = identityStore
        self.transport = transport
        self.configuration = configuration
    }

    /// The settings integration calls this immediately after persisting `LinuxSettings.analyticsEnabled`.
    public func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
    }

    public func captureDailyActive(_ snapshot: LinuxAnalyticsDailySnapshot) async -> LinuxAnalyticsDelivery {
        guard enabled else { return .disabled }
        guard let context = deliveryContext() else { return .invalidInput }

        let properties = DailyProperties(
            distinctID: context.installID,
            installID: context.installID,
            appVersion: bounded(configuration.appVersion, maximum: 64),
            osVersion: bounded(configuration.osVersion, maximum: 128),
            enabledProviders: identifiers(snapshot.enabledProviders),
            enabledMetricIDs: identifiers(snapshot.enabledMetricIDs),
            pinnedMetricIDs: identifiers(snapshot.pinnedMetricIDs),
            expandedMetricIDs: identifiers(snapshot.expandedMetricIDs),
            menuBarStyle: snapshot.menuBarStyle.rawValue
        )
        return await deliver(event: LinuxAnalyticsEvent.dailyActive, properties: properties, token: context.token)
    }

    public func captureProviderRefresh(_ rollup: LinuxAnalyticsProviderRollup) async -> LinuxAnalyticsDelivery {
        guard enabled else { return .disabled }
        guard let providerID = identifier(rollup.providerID),
              let context = deliveryContext()
        else { return .invalidInput }

        let errors = Dictionary(uniqueKeysWithValues: rollup.errorCounts.compactMap { category, count in
            let count = clampedCount(count)
            return count > 0 ? (category.rawValue, count) : nil
        })
        let expected = clampedCount(
            (errors[LinuxAnalyticsErrorCategory.notLoggedIn.rawValue] ?? 0)
                + (errors[LinuxAnalyticsErrorCategory.notAvailable.rawValue] ?? 0)
        )
        let failure = clampedCount(rollup.failureCount)
        let properties = ProviderProperties(
            distinctID: context.installID,
            providerID: providerID,
            successCount: clampedCount(rollup.successCount),
            failureCount: failure,
            errorCategories: errors,
            manualRefreshCount: clampedCount(rollup.manualRefreshCount),
            notLoggedInFailureCount: errors[LinuxAnalyticsErrorCategory.notLoggedIn.rawValue] ?? 0,
            authExpiredFailureCount: errors[LinuxAnalyticsErrorCategory.authExpired.rawValue] ?? 0,
            authInvalidFailureCount: errors[LinuxAnalyticsErrorCategory.authInvalid.rawValue] ?? 0,
            credentialAccessFailureCount: errors[LinuxAnalyticsErrorCategory.credentialAccess.rawValue] ?? 0,
            networkFailureCount: errors[LinuxAnalyticsErrorCategory.network.rawValue] ?? 0,
            decodingFailureCount: errors[LinuxAnalyticsErrorCategory.decoding.rawValue] ?? 0,
            http4xxFailureCount: errors[LinuxAnalyticsErrorCategory.http4xx.rawValue] ?? 0,
            http5xxFailureCount: errors[LinuxAnalyticsErrorCategory.http5xx.rawValue] ?? 0,
            rateLimitedFailureCount: errors[LinuxAnalyticsErrorCategory.rateLimited.rawValue] ?? 0,
            notAvailableFailureCount: errors[LinuxAnalyticsErrorCategory.notAvailable.rawValue] ?? 0,
            otherFailureCount: errors[LinuxAnalyticsErrorCategory.other.rawValue] ?? 0,
            expectedFailureCount: expected,
            unexpectedFailureCount: max(0, failure - expected)
        )
        return await deliver(
            event: LinuxAnalyticsEvent.providerRefreshDaily,
            properties: properties,
            token: context.token
        )
    }

    private func deliveryContext() -> (installID: String, token: String)? {
        let token = configuration.projectToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.hasPrefix("phc_"), token.utf8.count <= 256,
              let installID = try? identityStore.installID()
        else { return nil }
        return (installID, token)
    }

    private func deliver<Properties: Encodable & Sendable>(
        event: String,
        properties: Properties,
        token: String
    ) async -> LinuxAnalyticsDelivery {
        let envelope = Envelope(apiKey: token, event: event, properties: properties)
        guard let body = try? JSONEncoder().encode(envelope) else { return .invalidInput }
        guard body.count <= Self.maximumPayloadBytes else { return .payloadTooLarge }

        var request = URLRequest(url: configuration.endpoint, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("openusage-linux", forHTTPHeaderField: "User-Agent")
        do {
            let response = try await transport.execute(request)
            guard (200..<300).contains(response.statusCode) else {
                return .rejected(statusCode: response.statusCode)
            }
            return .sent
        } catch {
            return .transportFailure
        }
    }

    private func identifiers(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values {
            guard let safe = identifier(value), seen.insert(safe).inserted else { continue }
            result.append(safe)
            if result.count == Self.maximumIdentifiersPerProperty { break }
        }
        return result
    }

    private func identifier(_ value: String) -> String? {
        let bytes = Array(value.utf8)
        guard let first = bytes.first, bytes.count <= 64,
              (first >= 97 && first <= 122) || (first >= 48 && first <= 57)
        else { return nil }
        for byte in bytes {
            let alphanumeric = (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57)
            guard alphanumeric || byte == 46 || byte == 95 || byte == 45 else { return nil }
        }
        return value
    }

    private func bounded(_ value: String, maximum: Int) -> String {
        String(value.unicodeScalars.prefix(maximum))
    }

    private func clampedCount(_ value: Int) -> Int {
        min(max(0, value), Self.maximumCount)
    }
}

private struct Envelope<Properties: Encodable & Sendable>: Encodable, Sendable {
    let apiKey: String
    let event: String
    let properties: Properties

    private enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
        case event
        case properties
    }
}

private struct DailyProperties: Encodable, Sendable {
    let distinctID: String
    let installID: String
    let appVersion: String
    let osVersion: String
    let enabledProviders: [String]
    let enabledMetricIDs: [String]
    let pinnedMetricIDs: [String]
    let expandedMetricIDs: [String]
    let menuBarStyle: String

    private enum CodingKeys: String, CodingKey {
        case distinctID = "distinct_id"
        case installID = "install_id"
        case appVersion = "app_version"
        case osVersion = "os_version"
        case enabledProviders = "enabled_providers"
        case enabledMetricIDs = "enabled_metric_ids"
        case pinnedMetricIDs = "pinned_metric_ids"
        case expandedMetricIDs = "expanded_metric_ids"
        case menuBarStyle = "menu_bar_style"
    }
}

private struct ProviderProperties: Encodable, Sendable {
    let distinctID: String
    let providerID: String
    let successCount: Int
    let failureCount: Int
    let errorCategories: [String: Int]
    let manualRefreshCount: Int
    let notLoggedInFailureCount: Int
    let authExpiredFailureCount: Int
    let authInvalidFailureCount: Int
    let credentialAccessFailureCount: Int
    let networkFailureCount: Int
    let decodingFailureCount: Int
    let http4xxFailureCount: Int
    let http5xxFailureCount: Int
    let rateLimitedFailureCount: Int
    let notAvailableFailureCount: Int
    let otherFailureCount: Int
    let expectedFailureCount: Int
    let unexpectedFailureCount: Int

    private enum CodingKeys: String, CodingKey {
        case distinctID = "distinct_id"
        case providerID = "provider_id"
        case successCount = "success_count"
        case failureCount = "failure_count"
        case errorCategories = "error_categories"
        case manualRefreshCount = "manual_refresh_count"
        case notLoggedInFailureCount = "not_logged_in_failure_count"
        case authExpiredFailureCount = "auth_expired_failure_count"
        case authInvalidFailureCount = "auth_invalid_failure_count"
        case credentialAccessFailureCount = "credential_access_failure_count"
        case networkFailureCount = "network_failure_count"
        case decodingFailureCount = "decoding_failure_count"
        case http4xxFailureCount = "http_4xx_failure_count"
        case http5xxFailureCount = "http_5xx_failure_count"
        case rateLimitedFailureCount = "rate_limited_failure_count"
        case notAvailableFailureCount = "not_available_failure_count"
        case otherFailureCount = "other_failure_count"
        case expectedFailureCount = "expected_failure_count"
        case unexpectedFailureCount = "unexpected_failure_count"
    }
}
