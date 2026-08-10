import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Cloud Code adapter used when the Antigravity app is not running. It preserves the macOS endpoint
/// order and auth/transient failure distinction while keeping all transport details provider-local.
public struct AntigravityCloudCodeClient: AntigravityUsageFetching {
    public static let maximumResponseBytes = 512 * 1024
    private static let bases = [
        "https://daily-cloudcode-pa.googleapis.com",
        "https://cloudcode-pa.googleapis.com",
    ]
    private static let clientID = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    private static let clientSecret = "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"

    private let transport: any HTTPTransport
    private let maximumResponseBytes: Int

    public init(
        transport: any HTTPTransport = URLSessionTransport(),
        maximumResponseBytes: Int = AntigravityCloudCodeClient.maximumResponseBytes
    ) {
        self.transport = transport
        self.maximumResponseBytes = maximumResponseBytes
    }

    public func fetch(accessToken: String) async throws -> AntigravityUsagePayload {
        var sawReachableEndpoint = false
        for base in Self.bases {
            let summary = try await post(base + "/v1internal:retrieveUserQuotaSummary", token: accessToken, userAgent: "antigravity")
            switch summary {
            case .success(let data):
                return AntigravityUsagePayload(summary: data, plan: await loadPlan(base: base, token: accessToken))
            case .authFailure:
                throw AntigravityLinuxError.authExpired
            case .other(let reachable):
                sawReachableEndpoint = sawReachableEndpoint || reachable
            }

            // Older builds expose only per-model quotas. The mapper accepts this payload and pools it
            // into Session and Claude exactly like the macOS fallback.
            let models = try await post(base + "/v1internal:fetchAvailableModels", token: accessToken, userAgent: "antigravity")
            switch models {
            case .success(let data):
                return AntigravityUsagePayload(summary: data, plan: await loadPlan(base: base, token: accessToken))
            case .authFailure:
                throw AntigravityLinuxError.authExpired
            case .other(let reachable):
                sawReachableEndpoint = sawReachableEndpoint || reachable
            }
        }
        _ = sawReachableEndpoint
        throw AntigravityLinuxError.unavailable
    }

    public func refreshAccessToken(refreshToken: String) async throws -> AntigravityTokenRefresh {
        let form = [
            "client_id=\(Self.form(Self.clientID))",
            "client_secret=\(Self.form(Self.clientSecret))",
            "refresh_token=\(Self.form(refreshToken))",
            "grant_type=refresh_token",
        ].joined(separator: "&")
        guard let url = URL(string: "https://oauth2.googleapis.com/token") else {
            throw AntigravityLinuxError.unavailable
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = Data(form.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let response: HTTPResult
        do { response = try await transport.execute(request) }
        catch { throw AntigravityLinuxError.unavailable }
        try checkSize(response.data)
        switch response.statusCode {
        case 200..<300:
            guard let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
                  let token = (object["access_token"] as? String)?.antigravityTrimmedNonEmpty else {
                throw AntigravityLinuxError.unavailable
            }
            let expiresIn = (object["expires_in"] as? NSNumber)?.doubleValue ?? 3_600
            return AntigravityTokenRefresh(accessToken: token, expiresIn: expiresIn)
        case 408, 429, 500...599:
            throw AntigravityLinuxError.unavailable
        case 400..<500:
            throw AntigravityLinuxError.authExpired
        default:
            throw AntigravityLinuxError.unavailable
        }
    }

    private enum EndpointResult { case success(Data), authFailure, other(reachable: Bool) }

    private func post(
        _ address: String,
        token: String,
        userAgent: String,
        body: Data = Data("{}".utf8)
    ) async throws -> EndpointResult {
        guard let url = URL(string: address) else { return .other(reachable: false) }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let response: HTTPResult
        do { response = try await transport.execute(request) }
        catch { return .other(reachable: false) }
        try checkSize(response.data)
        if response.statusCode == 401 || response.statusCode == 403 { return .authFailure }
        if (200..<300).contains(response.statusCode) { return .success(response.data) }
        return .other(reachable: true)
    }

    private func loadPlan(base: String, token: String) async -> String? {
        let body = Data(#"{"metadata":{"ideType":"ANTIGRAVITY"}}"#.utf8)
        guard let result = try? await post(
            base + "/v1internal:loadCodeAssist",
            token: token,
            userAgent: "antigravity",
            body: body
        ),
              case .success(let data) = result else { return nil }
        return AntigravityLinuxUsageMapper.plan(from: data)
    }

    private func checkSize(_ data: Data) throws {
        guard data.count <= maximumResponseBytes else {
            throw AntigravityLinuxError.responseTooLarge(maximumBytes: maximumResponseBytes)
        }
    }

    private static func form(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? value
    }
}
