import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public actor ClaudeProviderClient {
    private let transport: any ProviderHTTPTransport
    private let now: @Sendable () -> Date
    private let environment: [String: String]
    private var cacheKey: String?
    private var lastGood: ProviderUsageSnapshot?
    private var rateLimitedUntil: Date?
    private static let refreshScopes = "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

    public init(
        transport: any ProviderHTTPTransport,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.transport = transport; self.environment = environment; self.now = now
    }

    public func refresh(
        configDirectory: URL,
        store: LinuxCredentialStore,
        instanceID: String = "claude",
        displayName: String = "Claude",
        accountLabel: String? = nil
    ) async throws -> ProviderUsageSnapshot {
        var credentials = try store.loadClaude(configDirectory: configDirectory)
        let scopes = credentials.scopes ?? []
        if !scopes.isEmpty && !scopes.contains("user:profile") { throw ClaudeProviderError.missingProfileScope }
        let key = credentials.accessToken + "\u{0}" + (credentials.refreshToken ?? "")
        if cacheKey != key { cacheKey = key; lastGood = nil; rateLimitedUntil = nil }
        if let until = rateLimitedUntil, now() < until {
            return staleOrLimited(credentials: credentials, retry: Int(ceil(until.timeIntervalSince(now()))))
        }
        if needsRefresh(credentials), let token = credentials.refreshToken, !token.isEmpty {
            credentials = try await rotate(credentials, refreshToken: token, configDirectory: configDirectory, store: store)
        }
        var response: ProviderHTTPResponse
        do { response = try await transport.execute(try usageRequest(token: credentials.accessToken)) }
        catch { throw ClaudeProviderError.connectionFailed }
        if response.statusCode == 401 {
            guard let token = credentials.refreshToken, !token.isEmpty else { throw ClaudeProviderError.tokenExpired }
            credentials = try await rotate(credentials, refreshToken: token, configDirectory: configDirectory, store: store)
            do { response = try await transport.execute(try usageRequest(token: credentials.accessToken)) }
            catch { throw ClaudeProviderError.connectionFailed }
            if response.statusCode == 401 { throw ClaudeProviderError.tokenExpired }
        }
        if response.statusCode == 429 {
            let retry = parseRetryAfter(response) ?? 300
            rateLimitedUntil = now().addingTimeInterval(TimeInterval(retry))
            return staleOrLimited(credentials: credentials, retry: parseRetryAfter(response))
        }
        let mapped = try ClaudeUsageMapper.map(response: response, instanceID: instanceID, displayName: displayName,
                                                accountLabel: accountLabel, credentials: credentials, now: now())
        lastGood = mapped; rateLimitedUntil = nil
        return mapped
    }

    private func rotate(_ credentials: ClaudeCredentials, refreshToken: String, configDirectory: URL,
                        store: LinuxCredentialStore) async throws -> ClaudeCredentials {
        let body: [String: Any] = ["grant_type": "refresh_token", "refresh_token": refreshToken,
                                  "client_id": oauthClientID(), "scope": Self.refreshScopes]
        var request = URLRequest(url: try refreshURL(), timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let response: ProviderHTTPResponse
        do { response = try await transport.execute(request) } catch { throw ClaudeProviderError.connectionFailed }
        if response.statusCode == 400 || response.statusCode == 401 {
            let error = parityJSON(response.body)?["error"] as? String
                ?? parityJSON(response.body)?["error_description"] as? String
            if error == "invalid_grant" { throw ClaudeProviderError.sessionExpired }
            throw ClaudeProviderError.requestFailed(response.statusCode)
        }
        guard (200..<300).contains(response.statusCode), let root = parityJSON(response.body),
              let access = root["access_token"] as? String, !access.isEmpty else {
            throw response.statusCode >= 200 && response.statusCode < 300
                ? ClaudeProviderError.invalidResponse : ClaudeProviderError.requestFailed(response.statusCode)
        }
        var updated = credentials
        updated.accessToken = access
        if let refresh = root["refresh_token"] as? String { updated.refreshToken = refresh }
        if let expires = parityNumber(root["expires_in"]) {
            updated.expiresAt = now().timeIntervalSince1970 * 1000 + expires * 1000
        }
        try store.saveClaude(updated, configDirectory: configDirectory)
        cacheKey = updated.accessToken + "\u{0}" + (updated.refreshToken ?? "")
        return updated
    }

    private func usageRequest(token: String) throws -> URLRequest {
        var request = URLRequest(url: try usageURL(), timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.69", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func endpointBase() -> String {
        if let custom = environment["CLAUDE_CODE_CUSTOM_OAUTH_URL"]?.trimmingCharacters(in: CharacterSet(charactersIn: "/")), !custom.isEmpty { return custom }
        if environment["USER_TYPE"] == "ant", flag("USE_LOCAL_OAUTH") {
            return (environment["CLAUDE_LOCAL_OAUTH_API_BASE"] ?? "http://localhost:8000").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        if environment["USER_TYPE"] == "ant", flag("USE_STAGING_OAUTH") { return "https://api-staging.anthropic.com" }
        return "https://api.anthropic.com"
    }
    private func usageURL() throws -> URL {
        let raw = endpointBase() + "/api/oauth/usage"
        guard let url = URL(string: raw), url.host != nil else { throw ClaudeProviderError.invalidOAuthURL(raw) }
        return url
    }
    private func refreshURL() throws -> URL {
        let raw: String
        if environment["CLAUDE_CODE_CUSTOM_OAUTH_URL"] != nil || (environment["USER_TYPE"] == "ant" && flag("USE_LOCAL_OAUTH")) {
            raw = endpointBase() + "/v1/oauth/token"
        } else if environment["USER_TYPE"] == "ant" && flag("USE_STAGING_OAUTH") {
            raw = "https://platform.staging.ant.dev/v1/oauth/token"
        } else { raw = "https://platform.claude.com/v1/oauth/token" }
        guard let url = URL(string: raw), url.host != nil else { throw ClaudeProviderError.invalidOAuthURL(raw) }
        return url
    }
    private func oauthClientID() -> String {
        environment["CLAUDE_CODE_OAUTH_CLIENT_ID"] ?? ((environment["USER_TYPE"] == "ant")
            ? "22422756-60c9-4084-8eb7-27705fd5cf9a" : "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
    }
    private func flag(_ key: String) -> Bool {
        guard let value = environment[key]?.lowercased() else { return false }
        return !["0", "false", "no", "off"].contains(value)
    }
    private func needsRefresh(_ credentials: ClaudeCredentials) -> Bool {
        guard let expiry = credentials.expiresAt else { return false }
        return expiry - now().timeIntervalSince1970 * 1000 <= 300_000
    }
    private func parseRetryAfter(_ response: ProviderHTTPResponse) -> Int? {
        guard let value = response.header("retry-after")?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return Int(value).flatMap { $0 >= 0 ? $0 : nil }
    }
    private func staleOrLimited(credentials: ClaudeCredentials, retry: Int?) -> ProviderUsageSnapshot {
        guard let stale = lastGood else { return ClaudeUsageMapper.rateLimited(credentials: credentials, retryAfterSeconds: retry, now: now()) }
        var metrics = stale.metrics
        metrics.append(UsageMetric(kind: .text, label: "Note", used: 0, text: "Live usage rate limited - data may be stale"))
        return ProviderUsageSnapshot(providerID: stale.providerID, instanceID: stale.instanceID, displayName: stale.displayName,
            accountLabel: stale.accountLabel, plan: stale.plan, metrics: metrics, links: stale.links, widgets: stale.widgets,
            refreshedAt: now(), warning: "Updates blocked by Anthropic. Be patient — manual refreshes will make it worse.")
    }
}
