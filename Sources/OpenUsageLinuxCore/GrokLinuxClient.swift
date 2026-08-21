import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct GrokLinuxClient: Sendable {
    public static let creditsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    public static let settingsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/settings")!
    public static let remainingResetsURL = GrokRemainingResets.url
    public static let refreshURL = URL(string: "https://auth.x.ai/oauth2/token")!
    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport = URLSessionTransport()) { self.transport = transport }

    public func credits(accessToken: String) async throws -> HTTPResult {
        try await transport.execute(authenticatedRequest(url: Self.creditsURL, token: accessToken))
    }

    public func settings(accessToken: String) async throws -> HTTPResult {
        try await transport.execute(authenticatedRequest(url: Self.settingsURL, token: accessToken))
    }

    /// Dedicated usage-limit reset tokens. Same CLI bearer as billing; empty grpc-web frame.
    public func remainingResets(accessToken: String) async throws -> HTTPResult {
        var request = authenticatedRequest(url: Self.remainingResetsURL, token: accessToken)
        request.httpMethod = "POST"
        request.httpBody = GrokRemainingResets.emptyRequest
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-Grpc-Web")
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Accept")
        request.setValue("https://grok.com", forHTTPHeaderField: "Origin")
        return try await transport.execute(request)
    }

    public func refresh(refreshToken: String, clientID: String) async throws -> HTTPResult {
        var request = URLRequest(url: Self.refreshURL, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = Data("grant_type=refresh_token&client_id=\(grokFormEncoded(clientID))&refresh_token=\(grokFormEncoded(refreshToken))".utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        return try await transport.execute(request)
    }

    private func authenticatedRequest(url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("OpenUsage", forHTTPHeaderField: "User-Agent")
        return request
    }
}

private func grokFormEncoded(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? value
}
