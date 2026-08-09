import Foundation

public enum ZAIProviderError: Error, LocalizedError, Equatable, Sendable {
    case missingKey
    case invalidKey
    case credentialAccess
    case connectionFailed
    case invalidResponse
    case responseTooLarge(maximumBytes: Int)
    case requestFailed(Int)
    case noCodingPlan

    public var category: ProviderErrorCategory {
        switch self {
        case .missingKey: .notLoggedIn
        case .invalidKey: .authInvalid
        case .credentialAccess: .credentialAccess
        case .connectionFailed: .network
        case .invalidResponse, .responseTooLarge: .decoding
        case .requestFailed(let status): .http(status)
        case .noCodingPlan: .notAvailable
        }
    }

    public var errorDescription: String? {
        switch self {
        case .missingKey:
            "No Z.ai API key. Set ZAI_API_KEY or add it to ~/.config/openusage/zai.json."
        case .invalidKey:
            "Z.ai API key invalid. Check your key at z.ai/manage-apikey/apikey-list."
        case .credentialAccess:
            "Couldn't read the Z.ai API key."
        case .connectionFailed:
            "Usage request failed. Check your connection."
        case .invalidResponse, .responseTooLarge:
            "Usage response invalid. Try again later."
        case .requestFailed(let status):
            "Usage request failed (HTTP \(status)). Try again later."
        case .noCodingPlan:
            "No active GLM Coding Plan. Subscribe at z.ai/subscribe to see usage."
        }
    }
}

public struct ZAILinuxProvider: Sendable {
    public static let links = [
        ProviderLink(label: "Dashboard", url: "https://z.ai/manage-apikey/coding-plan/personal/my-plan"),
        ProviderLink(label: "API Keys", url: "https://z.ai/manage-apikey/apikey-list"),
    ]
    public static let widgetDescriptors = [
        WidgetDescriptor(id: "zai.session", title: "Session", metricLabel: "Session"),
        WidgetDescriptor(id: "zai.weekly", title: "Weekly", metricLabel: "Weekly"),
        WidgetDescriptor(id: "zai.webSearches", title: "Web Searches", metricLabel: "Web Searches"),
    ]

    private let keySource: any ProviderAPIKeySource
    private let client: ZAILinuxClient
    private let now: @Sendable () -> Date

    public init(
        keySource: any ProviderAPIKeySource = ZAILinuxProvider.defaultKeySource(),
        client: ZAILinuxClient = ZAILinuxClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.keySource = keySource
        self.client = client
        self.now = now
    }

    public func fetch() async throws -> ProviderUsageSnapshot {
        let apiKey: String
        do {
            guard let loaded = try keySource.loadAPIKey() else { throw ZAIProviderError.missingKey }
            apiKey = loaded
        } catch let error as ZAIProviderError {
            throw error
        } catch {
            throw ZAIProviderError.credentialAccess
        }

        let quota: HTTPResult
        do { quota = try await client.fetchQuota(apiKey: apiKey) }
        catch let error as ZAIProviderError { throw error }
        catch { throw ZAIProviderError.connectionFailed }
        if quota.statusCode == 401 || quota.statusCode == 403 { throw ZAIProviderError.invalidKey }
        guard (200..<300).contains(quota.statusCode) else { throw ZAIProviderError.requestFailed(quota.statusCode) }
        if ZAILinuxMapper.isNoCodingPlan(quota.data) { throw ZAIProviderError.noCodingPlan }

        var subscriptionBody: Data?
        if let result = try? await client.fetchSubscription(apiKey: apiKey),
           (200..<300).contains(result.statusCode)
        {
            subscriptionBody = result.data
        }
        return try ZAILinuxMapper.map(quotaBody: quota.data, subscriptionBody: subscriptionBody, now: now())
    }

    public func refresh() async -> ProviderUsageSnapshot {
        do { return try await fetch() }
        catch {
            return ProviderUsageSnapshot(
                providerID: "zai",
                displayName: "Z.ai",
                plan: nil,
                metrics: [],
                links: Self.links,
                widgets: Self.widgetDescriptors,
                refreshedAt: now(),
                errorMessage: error.localizedDescription
            )
        }
    }
}
