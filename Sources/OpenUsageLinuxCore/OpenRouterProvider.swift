import Foundation

public enum OpenRouterProviderError: Error, LocalizedError, Equatable, Sendable {
    case missingKey
    case invalidKey
    case credentialAccess
    case connectionFailed
    case invalidResponse
    case responseTooLarge(maximumBytes: Int)
    case requestFailed(Int)

    public var category: ProviderErrorCategory {
        switch self {
        case .missingKey: .notLoggedIn
        case .invalidKey: .authInvalid
        case .credentialAccess: .credentialAccess
        case .connectionFailed: .network
        case .invalidResponse, .responseTooLarge: .decoding
        case .requestFailed(let status): .http(status)
        }
    }

    public var errorDescription: String? {
        switch self {
        case .missingKey:
            "No OpenRouter API key. Set OPENROUTER_API_KEY or add it to ~/.config/openusage/openrouter.json."
        case .invalidKey:
            "OpenRouter API key invalid. Check your key at openrouter.ai/keys."
        case .credentialAccess:
            "Couldn't read the OpenRouter API key."
        case .connectionFailed:
            "Couldn't reach OpenRouter. Check your connection."
        case .invalidResponse, .responseTooLarge:
            "OpenRouter usage data unavailable. Try again later."
        case .requestFailed(let status):
            "OpenRouter request failed (HTTP \(status))."
        }
    }
}

public struct OpenRouterLinuxProvider: Sendable {
    public static let links = [
        ProviderLink(label: "Activity", url: "https://openrouter.ai/activity"),
        ProviderLink(label: "Credits", url: "https://openrouter.ai/settings/credits"),
    ]
    public static let widgetDescriptors = [
        WidgetDescriptor(id: "openrouter.credits", title: "Credits", metricLabel: "Credits"),
        WidgetDescriptor(id: "openrouter.balance", title: "Balance", metricLabel: "Balance"),
        WidgetDescriptor(id: "openrouter.today", title: "Today", metricLabel: "Today"),
        WidgetDescriptor(id: "openrouter.week", title: "This Week", metricLabel: "This Week"),
        WidgetDescriptor(id: "openrouter.month", title: "This Month", metricLabel: "This Month"),
        WidgetDescriptor(id: "openrouter.keyLimit", title: "Key Limit", metricLabel: "Key Limit"),
    ]

    private let keySource: any ProviderAPIKeySource
    private let client: OpenRouterLinuxClient
    private let now: @Sendable () -> Date

    public init(
        keySource: any ProviderAPIKeySource = OpenRouterLinuxProvider.defaultKeySource(),
        client: OpenRouterLinuxClient = OpenRouterLinuxClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.keySource = keySource
        self.client = client
        self.now = now
    }

    public func fetch() async throws -> ProviderUsageSnapshot {
        let apiKey: String
        do {
            guard let loaded = try keySource.loadAPIKey() else { throw OpenRouterProviderError.missingKey }
            apiKey = loaded
        } catch let error as OpenRouterProviderError {
            throw error
        } catch {
            throw OpenRouterProviderError.credentialAccess
        }

        let credits = await endpoint { try await client.fetchCredits(apiKey: apiKey) }
        let key = await endpoint { try await client.fetchKey(apiKey: apiKey) }
        if credits.isAuthFailure && key.isAuthFailure { throw OpenRouterProviderError.invalidKey }

        let creditsBody = credits.body
        let keyBody = key.body
        if creditsBody != nil || keyBody != nil {
            return try OpenRouterLinuxMapper.map(creditsBody: creditsBody, keyBody: keyBody, now: now())
        }
        throw credits.error ?? key.error ?? OpenRouterProviderError.invalidResponse
    }

    public func refresh() async -> ProviderUsageSnapshot {
        do { return try await fetch() }
        catch {
            return ProviderUsageSnapshot(
                providerID: "openrouter",
                displayName: "OpenRouter",
                plan: nil,
                metrics: [],
                links: Self.links,
                widgets: Self.widgetDescriptors,
                refreshedAt: now(),
                errorMessage: error.localizedDescription
            )
        }
    }

    private func endpoint(_ operation: () async throws -> HTTPResult) async -> OpenRouterEndpointResult {
        do {
            let result = try await operation()
            if result.statusCode == 401 || result.statusCode == 403 { return .authFailure }
            guard (200..<300).contains(result.statusCode) else {
                return .failure(.requestFailed(result.statusCode))
            }
            return .success(result.data)
        } catch let error as OpenRouterProviderError {
            return .failure(error)
        } catch {
            return .failure(.connectionFailed)
        }
    }
}

private enum OpenRouterEndpointResult {
    case success(Data)
    case authFailure
    case failure(OpenRouterProviderError)

    var body: Data? {
        if case .success(let body) = self { return body }
        return nil
    }
    var isAuthFailure: Bool {
        if case .authFailure = self { return true }
        return false
    }
    var error: OpenRouterProviderError? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
