import Foundation
import Testing
@testable import OpenUsageLinuxCore

@Suite("Linux anonymous analytics")
struct LinuxAnalyticsTests {
    @Test("Unset analytics stay off and an explicit opt-in persists")
    func analyticsPreferenceDefaultsOffAndPersistsOptIn() throws {
        let unset = try LinuxSettings.decode(Data(#"{"schemaVersion":1}"#.utf8))
        #expect(!unset.analyticsEnabled)

        var optedIn = unset
        optedIn.analyticsEnabled = true
        let decoded = try LinuxSettings.decode(JSONEncoder().encode(optedIn))
        #expect(decoded.analyticsEnabled)
    }

    @Test("Opt-out performs no network or identity storage work")
    func optOutIsAHardStop() async throws {
        let fixture = fixture(enabled: false)
        let result = await fixture.client.captureDailyActive(.init(
            enabledProviders: ["claude"],
            enabledMetricIDs: ["claude.session"],
            pinnedMetricIDs: [],
            expandedMetricIDs: [],
            menuBarStyle: .text
        ))

        #expect(result == .disabled)
        #expect(await fixture.transport.requestCount == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.identityURL.path))
    }

    @Test("Daily-active uses the macOS event contract and excludes unsafe identifiers")
    func dailyActiveContractIsAnonymousAndBounded() async throws {
        let fixture = fixture(enabled: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = await fixture.client.captureDailyActive(.init(
            enabledProviders: ["claude", "person@example.com", "/home/person/.config"],
            enabledMetricIDs: ["claude.session", "token=provider-secret"],
            pinnedMetricIDs: ["claude.session"],
            expandedMetricIDs: ["codex.weekly"],
            menuBarStyle: .text
        ))
        #expect(result == .sent)

        let request = try #require(await fixture.transport.requests.first)
        #expect(request.url?.absoluteString == "https://us.i.posthog.com/capture/")
        #expect(request.httpMethod == "POST")
        let body = try #require(request.httpBody)
        #expect(body.count <= LinuxAnalyticsClient.maximumPayloadBytes)
        let envelope = try json(body)
        #expect(envelope["event"] as? String == "app_daily_active")
        let properties = try #require(envelope["properties"] as? [String: Any])
        #expect(Set(properties.keys) == [
            "distinct_id", "install_id", "app_version", "os_version", "enabled_providers",
            "enabled_metric_ids", "pinned_metric_ids", "expanded_metric_ids", "menu_bar_style",
        ])
        #expect(properties["enabled_providers"] as? [String] == ["claude"])
        #expect(properties["enabled_metric_ids"] as? [String] == ["claude.session"])
        #expect(properties["menu_bar_style"] as? String == "text")
        #expect(properties["distinct_id"] as? String == properties["install_id"] as? String)
        let serialized = String(decoding: body, as: UTF8.self)
        #expect(!serialized.contains("person@example.com"))
        #expect(!serialized.contains("/home/person"))
        #expect(!serialized.contains("provider-secret"))
    }

    @Test("Provider rollup matches macOS properties and clamps unbounded counts")
    func providerRollupContract() async throws {
        let fixture = fixture(enabled: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = await fixture.client.captureProviderRefresh(.init(
            providerID: "codex",
            successCount: Int.max,
            failureCount: 4,
            errorCounts: [.notLoggedIn: 2, .network: 1, .notAvailable: 1],
            manualRefreshCount: 2
        ))
        #expect(result == .sent)

        let request = try #require(await fixture.transport.requests.first)
        let envelope = try json(try #require(request.httpBody))
        #expect(envelope["event"] as? String == "provider_refresh_daily")
        let properties = try #require(envelope["properties"] as? [String: Any])
        #expect(properties["provider_id"] as? String == "codex")
        #expect(properties["success_count"] as? Int == LinuxAnalyticsClient.maximumCount)
        #expect(properties["failure_count"] as? Int == 4)
        #expect(properties["expected_failure_count"] as? Int == 3)
        #expect(properties["unexpected_failure_count"] as? Int == 1)
        #expect(properties["network_failure_count"] as? Int == 1)
        #expect(properties["manual_refresh_count"] as? Int == 2)
        #expect(properties["error_categories"] as? [String: Int] == [
            "not_logged_in": 2, "network": 1, "not_available": 1,
        ])
    }

    @Test("Delivery is one attempt only and install identity is stable outside Secret Service")
    func singleAttemptAndStableIdentity() async throws {
        let fixture = fixture(enabled: true, result: .failure(TestFailure()))
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let event = LinuxAnalyticsDailySnapshot(
            enabledProviders: ["claude"], enabledMetricIDs: [], pinnedMetricIDs: [],
            expandedMetricIDs: [], menuBarStyle: .bars
        )
        #expect(await fixture.client.captureDailyActive(event) == .transportFailure)
        #expect(await fixture.transport.requestCount == 1)

        let first = try LinuxAnalyticsIdentityStore(fileURL: fixture.identityURL).installID()
        let second = try LinuxAnalyticsIdentityStore(fileURL: fixture.identityURL).installID()
        #expect(first == second)
        #expect(UUID(uuidString: first) != nil)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.identityURL.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o077 == 0)
        #expect(fixture.identityURL.lastPathComponent == "analytics-install-id")
    }

    private func fixture(
        enabled: Bool,
        result: Result<HTTPResult, Error> = .success(HTTPResult(data: Data(), statusCode: 200))
    ) -> (client: LinuxAnalyticsClient, transport: RecordingAnalyticsTransport, root: URL, identityURL: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let identityURL = root.appendingPathComponent("config/openusage/analytics-install-id")
        let transport = RecordingAnalyticsTransport(result: result)
        let client = LinuxAnalyticsClient(
            enabled: enabled,
            identityStore: LinuxAnalyticsIdentityStore(fileURL: identityURL),
            transport: transport,
            configuration: LinuxAnalyticsConfiguration(
                projectToken: "phc_test_public_ingestion_key",
                endpoint: URL(string: "https://us.i.posthog.com/capture/")!,
                appVersion: "1.2.3",
                osVersion: "Linux 6.1"
            )
        )
        return (client, transport, root, identityURL)
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private struct TestFailure: Error {}

private actor RecordingAnalyticsTransport: HTTPTransport {
    private(set) var requests: [URLRequest] = []
    let result: Result<HTTPResult, Error>

    init(result: Result<HTTPResult, Error>) {
        self.result = result
    }

    var requestCount: Int { requests.count }

    func execute(_ request: URLRequest) async throws -> HTTPResult {
        requests.append(request)
        return try result.get()
    }
}
