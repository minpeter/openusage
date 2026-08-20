import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CursorCopilotURLSessionTransport: HTTPTransport {
    public init() {}

    public func execute(_ request: URLRequest) async throws -> HTTPResult {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CursorLinuxError.invalidResponse }
        return HTTPResult(data: data, statusCode: response.statusCode)
    }
}

public struct CursorLinuxProvider: Sendable {
    public static let links = [
        ProviderLink(label: "Status", url: "https://status.cursor.com/"),
        ProviderLink(label: "Dashboard", url: "https://www.cursor.com/dashboard"),
    ]
    public static let widgets = [
        WidgetDescriptor(id: "cursor.usage", title: "Total Usage", metricLabel: "Total usage"),
        WidgetDescriptor(id: "cursor.auto", title: "Auto Usage", metricLabel: "Auto usage"),
        WidgetDescriptor(id: "cursor.api", title: "API Usage", metricLabel: "API usage"),
        WidgetDescriptor(id: "cursor.grokBotWeekly", title: "Grok Bot Weekly", metricLabel: "Grok Bot weekly"),
        WidgetDescriptor(id: "cursor.onDemand", title: "Extra Usage", metricLabel: "On-demand"),
        WidgetDescriptor(id: "cursor.requests", title: "Requests", metricLabel: "Requests"),
        WidgetDescriptor(id: "cursor.credits", title: "Credits", metricLabel: "Credits"),
        WidgetDescriptor(id: "cursor.usageTrend", title: "Usage Trend", metricLabel: "Usage Trend"),
        WidgetDescriptor(id: "cursor.today", title: "Today", metricLabel: "Today"),
        WidgetDescriptor(id: "cursor.yesterday", title: "Yesterday", metricLabel: "Yesterday"),
        WidgetDescriptor(id: "cursor.last30", title: "Last 30 Days", metricLabel: "Last 30 Days"),
    ]

    private let credentials: CursorLinuxCredentialStore
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date

    public init(credentials: CursorLinuxCredentialStore = CursorLinuxCredentialStore(), transport: any HTTPTransport = CursorCopilotURLSessionTransport(), now: @escaping @Sendable () -> Date = Date.init) {
        self.credentials = credentials; self.transport = transport; self.now = now
    }

    public func refresh() async throws -> ProviderUsageSnapshot {
        let credential = try credentials.load()
        var token = credential.accessToken
        if CursorLinuxCredentialStore.expiration(token)?.timeIntervalSince(now()) ?? 0 <= 300, let refresh = credential.refreshToken {
            if let rotated = try await rotate(refresh) { token = rotated; try credentials.saveAccessToken(rotated, for: credential) }
        }
        var usage = try await execute(CursorLinuxClient.usageRequest(accessToken: token))
        if usage.statusCode == 401 || usage.statusCode == 403, let refresh = credential.refreshToken {
            guard let rotated = try await rotate(refresh) else { throw CursorLinuxError.tokenExpired }
            token = rotated; try credentials.saveAccessToken(rotated, for: credential)
            usage = try await execute(CursorLinuxClient.usageRequest(accessToken: token))
        }
        if usage.statusCode == 401 || usage.statusCode == 403 { throw CursorLinuxError.tokenExpired }
        guard (200..<300).contains(usage.statusCode) else { throw CursorLinuxError.requestFailed(usage.statusCode) }
        let usageBody = try cursorProviderJSON(usage.data)
        let planResult = try? await execute(CursorLinuxClient.planRequest(accessToken: token))
        let planBody = planResult.flatMap { (200..<300).contains($0.statusCode) ? try? cursorProviderJSON($0.data) : nil }
        let planName = (planBody?["planInfo"] as? [String: Any])?["planName"] as? String
        let sandUsage = await optional(CursorLinuxClient.sandUsageRequest(accessToken: token))
        if CursorLinuxMapper.shouldFallback(usageBody, planName: planName, planUnavailable: planBody == nil) {
            let summary = await optional(CursorLinuxClient.usageSummaryRequest(accessToken: token))
            let requests = await optional(CursorLinuxClient.requestUsageRequest(accessToken: token))
            return try CursorLinuxMapper.mapRequestBased(summary: summary, requests: requests, planName: planName,
                                                         accountLabel: CursorLinuxCredentialStore.accountLabel(token),
                                                         sandUsage: sandUsage, now: now())
        }
        let grants = await optional(CursorLinuxClient.creditsRequest(accessToken: token))
        let stripe = await optional(CursorLinuxClient.stripeRequest(accessToken: token)).flatMap { cursorProviderNumber($0["customerBalance"]) }.flatMap { $0 < 0 ? abs($0) : 0 } ?? 0
        return try CursorLinuxMapper.map(usage: usageBody, planName: planName, creditGrants: grants,
                                         stripeBalanceCents: stripe, accountLabel: CursorLinuxCredentialStore.accountLabel(token),
                                         sandUsage: sandUsage, now: now())
    }

    private func rotate(_ refresh: String) async throws -> String? {
        let result = try await execute(CursorLinuxClient.refreshRequest(refreshToken: refresh))
        if result.statusCode == 400 || result.statusCode == 401 {
            let body = try? cursorProviderJSON(result.data)
            if body?["shouldLogout"] as? Bool == true { throw CursorLinuxError.sessionExpired }
            throw CursorLinuxError.tokenExpired
        }
        guard (200..<300).contains(result.statusCode), let body = try? cursorProviderJSON(result.data) else { return nil }
        if body["shouldLogout"] as? Bool == true { throw CursorLinuxError.sessionExpired }
        return (body["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    private func optional(_ request: URLRequest?) async -> [String: Any]? {
        guard let request, let result = try? await transport.execute(request), (200..<300).contains(result.statusCode) else { return nil }
        return try? cursorProviderJSON(result.data)
    }

    private func execute(_ request: URLRequest) async throws -> HTTPResult {
        do { return try await transport.execute(request) } catch { throw CursorLinuxError.connectionFailed }
    }
}

private func cursorProviderJSON(_ data: Data) throws -> [String: Any] {
    guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CursorLinuxError.invalidResponse }
    return value
}

private func cursorProviderNumber(_ value: Any?) -> Double? {
    if value is Bool { return nil }
    if let value = value as? NSNumber { return value.doubleValue }
    if let value = value as? String { return Double(value) }
    return nil
}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }
