import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CodexProviderClient: Sendable {
    public static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    public static let resetCreditsURL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
    public static let consumeResetCreditURL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume")!
    private static let refreshURL = URL(string: "https://auth.openai.com/oauth/token")!
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    private let transport: any ProviderHTTPTransport
    private let now: @Sendable () -> Date

    public init(transport: any ProviderHTTPTransport, now: @escaping @Sendable () -> Date = Date.init) {
        self.transport = transport; self.now = now
    }

    public func refresh(credentials initial: CodexCredentials, store: LinuxCredentialStore? = nil) async throws -> ProviderUsageSnapshot {
        var credentials = initial
        guard !credentials.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw credentials.apiKey?.isEmpty == false ? CodexProviderError.usageAPIKey : CodexProviderError.notLoggedIn
        }
        if needsRefresh(credentials), let refresh = credentials.refreshToken, !refresh.isEmpty {
            credentials = try await rotate(credentials, refreshToken: refresh, store: store)
        }
        var response = try await execute(usageRequest(credentials))
        if response.statusCode == 401 {
            guard let refresh = credentials.refreshToken, !refresh.isEmpty else { throw CodexProviderError.tokenExpired }
            credentials = try await rotate(credentials, refreshToken: refresh, store: store)
            response = try await execute(usageRequest(credentials))
            if response.statusCode == 401 { throw CodexProviderError.tokenExpired }
        }
        let resetResponse = try? await execute(resetCreditsRequest(credentials))
        return try CodexUsageMapper.map(response: response, resetCredits: resetResponse,
                                        accountLabel: credentials.accountLabel, now: now())
    }

    public func claimResetCredit(
        credentials: CodexCredentials,
        expiringAt expiry: Date,
        redeemRequestID: String
    ) async throws -> ResetClaimOutcome {
        let list = try await execute(resetCreditsRequest(credentials))
        guard (200..<300).contains(list.statusCode), let root = parityJSON(list.body) else { return .failed }
        guard let creditID = Self.creditID(in: root, expiringAt: expiry) else { return .noCredit }
        var request = authenticatedRequest(url: Self.consumeResetCreditURL, credentials: credentials, timeout: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "credit_id": creditID, "redeem_request_id": redeemRequestID,
        ], options: [.sortedKeys])
        let response = try await execute(request)
        return Self.claimOutcome(response)
    }

    public static func creditID(in body: [String: Any], expiringAt expiry: Date) -> String? {
        (body["credits"] as? [[String: Any]])?.first { credit in
            if let status = credit["status"] as? String, status != "available" { return false }
            guard let date = parityDate(credit["expires_at"]) else { return false }
            return abs(date.timeIntervalSince(expiry)) < 1
        }?["id"] as? String
    }

    public static func claimOutcome(_ response: ProviderHTTPResponse) -> ResetClaimOutcome {
        guard (200..<300).contains(response.statusCode), let code = parityJSON(response.body)?["code"] as? String else { return .failed }
        switch code {
        case "reset", "already_redeemed": return .success
        case "nothing_to_reset": return .nothingToReset
        case "no_credit": return .noCredit
        default: return .failed
        }
    }

    private func rotate(_ current: CodexCredentials, refreshToken: String,
                        store: LinuxCredentialStore?) async throws -> CodexCredentials {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value }
        let body = "grant_type=refresh_token&client_id=\(Self.clientID)&refresh_token=\(encode(refreshToken))"
        var request = URLRequest(url: Self.refreshURL, timeoutInterval: 15)
        request.httpMethod = "POST"; request.httpBody = Data(body.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let response = try await execute(request)
        if response.statusCode == 400 || response.statusCode == 401 {
            let root = parityJSON(response.body)
            let nested = root?["error"] as? [String: Any]
            let code = nested?["code"] as? String ?? nested?["error"] as? String
                ?? root?["error"] as? String ?? root?["code"] as? String
            switch code {
            case "refresh_token_expired": throw CodexProviderError.sessionExpired
            case "refresh_token_reused": throw CodexProviderError.tokenConflict
            case "refresh_token_invalidated": throw CodexProviderError.tokenRevoked
            default: throw CodexProviderError.requestFailed(response.statusCode)
            }
        }
        guard (200..<300).contains(response.statusCode), let root = parityJSON(response.body),
              let access = root["access_token"] as? String, !access.isEmpty else {
            if (200..<300).contains(response.statusCode) { throw CodexProviderError.tokenExpired }
            throw CodexProviderError.requestFailed(response.statusCode)
        }
        var updated = current
        updated.accessToken = access
        if let token = root["refresh_token"] as? String { updated.refreshToken = token }
        if let token = root["id_token"] as? String { updated.idToken = token }
        updated.lastRefresh = ISO8601DateFormatter().string(from: now())
        if let store { try? store.saveCodex(updated) }
        return updated
    }

    private func usageRequest(_ credentials: CodexCredentials) -> URLRequest {
        authenticatedRequest(url: Self.usageURL, credentials: credentials, timeout: 10)
    }
    private func resetCreditsRequest(_ credentials: CodexCredentials) -> URLRequest {
        var request = authenticatedRequest(url: Self.resetCreditsURL, credentials: credentials, timeout: 10)
        request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        return request
    }
    private func authenticatedRequest(url: URL, credentials: CodexCredentials, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("OpenUsage", forHTTPHeaderField: "User-Agent")
        if let account = credentials.accountID, !account.isEmpty {
            request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        return request
    }
    private func execute(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        do { return try await transport.execute(request) } catch { throw CodexProviderError.connectionFailed }
    }
    private func needsRefresh(_ credentials: CodexCredentials) -> Bool {
        if let expiry = jwtExpiry(credentials.accessToken) { return expiry.timeIntervalSince(now()) <= 300 }
        guard let text = credentials.lastRefresh, let date = ISO8601DateFormatter().date(from: text) else { return false }
        return now().timeIntervalSince(date) > 8 * 86_400
    }
    private func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: "."); guard parts.count > 1 else { return nil }
        var value = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let data = Data(base64Encoded: value), let exp = parityNumber(parityJSON(data)?["exp"]) else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}
