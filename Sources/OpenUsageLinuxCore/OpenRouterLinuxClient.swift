import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct OpenRouterLinuxClient: Sendable {
    public static let creditsURL = "https://openrouter.ai/api/v1/credits"
    public static let keyURL = "https://openrouter.ai/api/v1/key"
    public static let maximumResponseBytes = 512 * 1024

    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    public func makeRequest(url urlString: String, apiKey: String) throws -> URLRequest {
        guard let url = URL(string: urlString) else { throw OpenRouterProviderError.invalidResponse }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    public func fetchCredits(apiKey: String) async throws -> HTTPResult {
        try await get(Self.creditsURL, apiKey: apiKey)
    }

    public func fetchKey(apiKey: String) async throws -> HTTPResult {
        try await get(Self.keyURL, apiKey: apiKey)
    }

    private func get(_ url: String, apiKey: String) async throws -> HTTPResult {
        let result = try await transport.execute(makeRequest(url: url, apiKey: apiKey))
        guard result.data.count <= Self.maximumResponseBytes else {
            throw OpenRouterProviderError.responseTooLarge(maximumBytes: Self.maximumResponseBytes)
        }
        return result
    }
}
