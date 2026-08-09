import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public actor CopilotLinuxProvider {
    public static let links = [
        ProviderLink(label: "Status", url: "https://www.githubstatus.com/"),
        ProviderLink(label: "Dashboard", url: "https://github.com/settings/billing"),
    ]
    public static let widgets = [
        WidgetDescriptor(id: "copilot.premium", title: "Credits", metricLabel: "Credits"),
        WidgetDescriptor(id: "copilot.extra", title: "Extra Usage", metricLabel: "Extra Usage"),
        WidgetDescriptor(id: "copilot.orgCredits", title: "Org Credits", metricLabel: "Org Credits"),
        WidgetDescriptor(id: "copilot.orgSpend", title: "Org Spend", metricLabel: "Org Spend"),
        WidgetDescriptor(id: "copilot.chat", title: "Chat", metricLabel: "Chat"),
        WidgetDescriptor(id: "copilot.completions", title: "Completions", metricLabel: "Completions"),
    ]

    private let credentials: CopilotLinuxCredentialStore
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date
    private var rememberedOrganization: String?

    public init(credentials: CopilotLinuxCredentialStore = CopilotLinuxCredentialStore(), transport: any HTTPTransport = CursorCopilotURLSessionTransport(),
                rememberedOrganization: String? = nil, now: @escaping @Sendable () -> Date = Date.init) {
        self.credentials = credentials; self.transport = transport; self.rememberedOrganization = rememberedOrganization; self.now = now
    }

    public func refresh() async throws -> ProviderUsageSnapshot {
        let credential = try credentials.load()
        let response = try await execute(CopilotLinuxClient.usageRequest(token: credential.token))
        if response.statusCode == 401 || response.statusCode == 403 { throw CopilotLinuxError.tokenInvalid }
        guard (200..<300).contains(response.statusCode) else { throw CopilotLinuxError.requestFailed(response.statusCode) }
        guard let body = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else { throw CopilotLinuxError.invalidResponse }
        let mapped = try CopilotLinuxMapper.mapped(body: body, accountLabel: credential.accountLabel, now: now())
        guard mapped.isOrganizationManaged else { return mapped.snapshot }
        let orgMetrics = await organizationMetrics(token: credential.token)
        return ProviderUsageSnapshot(providerID: "copilot", displayName: "Copilot", accountLabel: credential.accountLabel,
                                     plan: mapped.snapshot.plan, metrics: orgMetrics, links: Self.links, widgets: Self.widgets, refreshedAt: now())
    }

    private func organizationMetrics(token: String) async -> [UsageMetric] {
        if let rememberedOrganization {
            do {
                if let metrics = try await billing(org: rememberedOrganization, token: token) { return metrics }
                self.rememberedOrganization = nil
            } catch { return [] }
        }
        guard let result = try? await transport.execute(CopilotLinuxClient.organizationsRequest(token: token)), result.statusCode == 200 else { return [] }
        for org in CopilotLinuxMapper.organizationLogins(data: result.data) {
            do {
                if let metrics = try await billing(org: org, token: token) {
                    rememberedOrganization = org
                    return metrics
                }
            } catch { continue }
        }
        return []
    }

    private func billing(org: String, token: String) async throws -> [UsageMetric]? {
        let result = try await transport.execute(CopilotLinuxClient.organizationBillingRequest(org: org, token: token))
        guard result.statusCode == 200 else {
            if result.statusCode == 429 || result.statusCode >= 500 { throw CopilotLinuxError.requestFailed(result.statusCode) }
            return nil
        }
        guard let body = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any] else { return nil }
        return CopilotLinuxMapper.mapOrganizationBilling(body: body)
    }

    private func execute(_ request: URLRequest) async throws -> HTTPResult {
        do { return try await transport.execute(request) } catch { throw CopilotLinuxError.connectionFailed }
    }
}
