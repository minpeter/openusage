import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum GrokLinuxError: Error, LocalizedError, Equatable, Sendable {
    case notLoggedIn
    case invalidAuth
    case expired
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)
    case localDataTooLarge

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn: "Grok not logged in. Run `grok login`."
        case .invalidAuth: "Grok auth invalid. Run `grok login` again."
        case .expired: "Grok auth expired. Run `grok login` again."
        case .connectionFailed: "Grok billing request failed. Check your connection."
        case .invalidResponse: "Grok billing response changed."
        case .requestFailed(let status): "Grok billing request failed (HTTP \(status)). Try again later."
        case .localDataTooLarge: "Grok local data exceeds the 512 KiB read limit."
        }
    }
}

public struct GrokLinuxProvider: Sendable {
    public static let links = [ProviderLink(label: "Usage", url: "https://grok.com/?_s=usage")]
    public static let widgetDescriptors = [
        WidgetDescriptor(id: "grok.weekly", title: "Weekly", metricLabel: "Weekly limit"),
        WidgetDescriptor(id: "grok.payAsYouGo", title: "Extra Usage", metricLabel: "Pay as you go"),
        WidgetDescriptor(id: "grok.trend", title: "Usage Trend", metricLabel: "Usage Trend"),
        WidgetDescriptor(id: "grok.today", title: "Today", metricLabel: "Today"),
        WidgetDescriptor(id: "grok.yesterday", title: "Yesterday", metricLabel: "Yesterday"),
        WidgetDescriptor(id: "grok.last30", title: "Last 30 Days", metricLabel: "Last 30 Days"),
    ]

    private let credentials: GrokLinuxCredentialStore
    private let client: GrokLinuxClient
    private let scanner: GrokLinuxLogScanner

    public init(
        credentials: GrokLinuxCredentialStore = GrokLinuxCredentialStore(),
        client: GrokLinuxClient = GrokLinuxClient(),
        scanner: GrokLinuxLogScanner = GrokLinuxLogScanner()
    ) {
        self.credentials = credentials
        self.client = client
        self.scanner = scanner
    }

    public func refresh(now: Date = Date()) async throws -> ProviderUsageSnapshot {
        let candidates = try credentials.loadCandidates()
        var lastError: Error = GrokLinuxError.invalidAuth
        for candidate in candidates {
            do {
                var auth = candidate
                if let expiry = auth.expiresAt, expiry.timeIntervalSince(now) <= 300 {
                    auth = try await rotated(auth, now: now)
                }
                var result = try await client.credits(accessToken: auth.accessToken)
                if result.statusCode == 401 || result.statusCode == 403 {
                    auth = try await rotated(auth, now: now)
                    result = try await client.credits(accessToken: auth.accessToken)
                }
                if result.statusCode == 401 || result.statusCode == 403 { throw GrokLinuxError.expired }
                guard (200..<300).contains(result.statusCode) else { throw GrokLinuxError.requestFailed(result.statusCode) }
                let settings = try? await client.settings(accessToken: auth.accessToken)
                let plan = settings.flatMap { response -> String? in
                    guard (200..<300).contains(response.statusCode),
                          let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any]
                    else { return nil }
                    return grokTrimmed(object["subscription_tier_display"] as? String)
                }
                let local = (try? scanner.scan(now: now)) ?? []
                return try GrokLinuxMapper.mapCredits(data: result.data, auth: auth, plan: plan, localMetrics: local, now: now)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func rotated(_ auth: GrokCredential, now: Date) async throws -> GrokCredential {
        guard let refreshToken = auth.refreshToken else { throw GrokLinuxError.expired }
        let result: HTTPResult
        do { result = try await client.refresh(refreshToken: refreshToken, clientID: auth.clientID) }
        catch { throw GrokLinuxError.connectionFailed }
        guard (200..<300).contains(result.statusCode), result.data.count <= 512 * 1024,
              let object = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any],
              let token = grokTrimmed(object["access_token"] as? String)
        else { throw GrokLinuxError.expired }
        var updated = auth
        updated.accessToken = token
        updated.refreshToken = grokTrimmed(object["refresh_token"] as? String) ?? auth.refreshToken
        updated.idToken = grokTrimmed(object["id_token"] as? String) ?? auth.idToken
        updated.expiresAt = linuxNumber(object["expires_in"]).map { now.addingTimeInterval($0) }
            ?? grokJWTExpiry(token) ?? now.addingTimeInterval(3600)
        try? credentials.saveRotated(updated)
        return updated
    }
}
