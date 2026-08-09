import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ZAILinuxClient: Sendable {
    public static let subscriptionURL = "https://api.z.ai/api/biz/subscription/list"
    public static let quotaURL = "https://api.z.ai/api/monitor/usage/quota/limit"
    public static let maximumResponseBytes = 512 * 1024

    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    public func makeRequest(url urlString: String, apiKey: String) throws -> URLRequest {
        guard let url = URL(string: urlString) else { throw ZAIProviderError.invalidResponse }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    public func fetchQuota(apiKey: String) async throws -> HTTPResult {
        try await get(Self.quotaURL, apiKey: apiKey)
    }

    public func fetchSubscription(apiKey: String) async throws -> HTTPResult {
        try await get(Self.subscriptionURL, apiKey: apiKey)
    }

    private func get(_ url: String, apiKey: String) async throws -> HTTPResult {
        let result = try await transport.execute(makeRequest(url: url, apiKey: apiKey))
        guard result.data.count <= Self.maximumResponseBytes else {
            throw ZAIProviderError.responseTooLarge(maximumBytes: Self.maximumResponseBytes)
        }
        return result
    }
}
