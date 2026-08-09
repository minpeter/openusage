import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import OpenUsageLinuxCore

@Suite("OpenRouter and Z.ai Linux parity")
struct OpenRouterZAIParityTests {
    @Test("API key sources preserve precedence and accept a Secret Service adapter")
    func apiKeySources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let json = root.appendingPathComponent("key.json")
        let plain = root.appendingPathComponent("key.txt")
        try Data(#"{"api_key":"file-key"}"#.utf8).write(to: json)
        try Data(" plain-key\n".utf8).write(to: plain)

        let secret = ClosureAPIKeySource { "secret-key" }
        let environment = EnvironmentAPIKeySource(
            names: ["OPENROUTER_API_KEY", "OPENROUTER_KEY"],
            environment: ["OPENROUTER_KEY": " env-key "]
        )
        let files = FileAPIKeySource(urls: [json, plain])

        #expect(try CompositeAPIKeySource(sources: [secret, environment, files]).loadAPIKey() == "secret-key")
        #expect(try CompositeAPIKeySource(sources: [environment, files]).loadAPIKey() == "env-key")
        #expect(try files.loadAPIKey() == "file-key")
        #expect(try FileAPIKeySource(urls: [plain]).loadAPIKey() == "plain-key")
    }

    @Test("Provider defaults expose the macOS key source order")
    func providerKeySourceDefaults() throws {
        #expect(OpenRouterLinuxProvider.environmentNames == ["OPENROUTER_API_KEY", "OPENROUTER_KEY"])
        #expect(OpenRouterLinuxProvider.configPaths == [
            "~/.config/openusage/openrouter.json", "~/.config/openrouter/key.json",
        ])
        #expect(ZAILinuxProvider.environmentNames == ["ZAI_API_KEY", "GLM_API_KEY"])
        #expect(ZAILinuxProvider.configPaths == [
            "~/.config/openusage/zai.json", "~/.config/zai/key.json",
        ])

        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".config/openusage")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try Data(#"{"apiKey":"openrouter-file"}"#.utf8).write(to: config.appendingPathComponent("openrouter.json"))
        try Data(#"{"apiKey":"zai-file"}"#.utf8).write(to: config.appendingPathComponent("zai.json"))

        #expect(try OpenRouterLinuxProvider.defaultKeySource(environment: [
            "HOME": home.path, "OPENROUTER_API_KEY": "openrouter-env",
        ]).loadAPIKey() == "openrouter-file")
        #expect(try ZAILinuxProvider.defaultKeySource(environment: [
            "HOME": home.path, "ZAI_API_KEY": "zai-env",
        ]).loadAPIKey() == "zai-file")
    }

    @Test("Requests use exact endpoints and bearer headers")
    func requestContracts() throws {
        let openRouter = OpenRouterLinuxClient(transport: FixtureTransport(results: []))
        let zai = ZAILinuxClient(transport: FixtureTransport(results: []))

        let credits = try openRouter.makeRequest(url: OpenRouterLinuxClient.creditsURL, apiKey: "or-key")
        let key = try openRouter.makeRequest(url: OpenRouterLinuxClient.keyURL, apiKey: "or-key")
        let quota = try zai.makeRequest(url: ZAILinuxClient.quotaURL, apiKey: "zai-key")
        let subscription = try zai.makeRequest(url: ZAILinuxClient.subscriptionURL, apiKey: "zai-key")

        #expect(credits.url?.absoluteString == "https://openrouter.ai/api/v1/credits")
        #expect(key.url?.absoluteString == "https://openrouter.ai/api/v1/key")
        #expect(quota.url?.absoluteString == "https://api.z.ai/api/monitor/usage/quota/limit")
        #expect(subscription.url?.absoluteString == "https://api.z.ai/api/biz/subscription/list")
        #expect([credits, key, quota, subscription].allSatisfy { $0.httpMethod == "GET" })
        #expect(credits.value(forHTTPHeaderField: "Authorization") == "Bearer or-key")
        #expect(quota.value(forHTTPHeaderField: "Authorization") == "Bearer zai-key")
        #expect([credits, key, quota, subscription].allSatisfy {
            $0.value(forHTTPHeaderField: "Accept") == "application/json" && $0.timeoutInterval == 15
        })
    }

    @Test("Provider clients reject responses beyond the 512 KiB budget")
    func responseBudget() async {
        let oversized = HTTPResult(data: Data(repeating: 0, count: 512 * 1024 + 1), statusCode: 200)
        let openRouter = OpenRouterLinuxClient(transport: FixtureTransport(results: [.success(oversized)]))
        let zai = ZAILinuxClient(transport: FixtureTransport(results: [.success(oversized)]))

        await #expect(throws: OpenRouterProviderError.responseTooLarge(maximumBytes: 512 * 1024)) {
            try await openRouter.fetchCredits(apiKey: "key")
        }
        await #expect(throws: ZAIProviderError.responseTooLarge(maximumBytes: 512 * 1024)) {
            try await zai.fetchQuota(apiKey: "key")
        }
    }

    @Test("OpenRouter maps every metric and exact account metadata")
    func openRouterMapping() throws {
        let snapshot = try OpenRouterLinuxMapper.map(
            creditsBody: Data(#"{"data":{"total_credits":277.47,"total_usage":178.2}}"#.utf8),
            keyBody: Data(#"{"data":{"is_free_tier":false,"usage_daily":0,"usage_weekly":1.25,"usage_monthly":4.5,"usage":2,"limit":5}}"#.utf8),
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        #expect(snapshot.providerID == "openrouter")
        #expect(snapshot.instanceID == "openrouter")
        #expect(snapshot.displayName == "OpenRouter")
        #expect(snapshot.accountLabel == nil)
        #expect(snapshot.plan == "Pay as you go")
        #expect(snapshot.metrics.map(\.label) == ["Credits", "Balance", "Today", "This Week", "This Month", "Key Limit"])
        let values = Dictionary(uniqueKeysWithValues: snapshot.metrics.map { ($0.label, $0) })
        #expect(abs(try #require(values["Credits"]).used - 178.2) < 0.000_001)
        #expect(abs(try #require(values["Balance"]).used - 99.27) < 0.000_001)
        #expect(try #require(values["Today"]).used == 0)
        #expect(try #require(values["This Week"]).used == 1.25)
        #expect(try #require(values["This Month"]).used == 4.5)
        #expect(try #require(values["Key Limit"]).used == 2)
        #expect(try #require(values["Credits"]).limit == 277.47)
        #expect(try #require(values["Key Limit"]).limit == 5)
        #expect(snapshot.links == OpenRouterLinuxProvider.links)
        #expect(snapshot.widgets == OpenRouterLinuxProvider.widgetDescriptors)
    }

    @Test("OpenRouter keeps independently successful endpoint data")
    func openRouterPartialSuccess() async {
        let transport = FixtureTransport(results: [
            .success(HTTPResult(data: Data("{}".utf8), statusCode: 403)),
            .success(HTTPResult(data: Data(#"{"data":{"is_free_tier":true,"usage_daily":0.5}}"#.utf8), statusCode: 200)),
        ])
        let provider = OpenRouterLinuxProvider(
            keySource: ClosureAPIKeySource { "key" },
            client: OpenRouterLinuxClient(transport: transport)
        )

        let snapshot = await provider.refresh()

        #expect(snapshot.errorMessage == nil)
        #expect(snapshot.plan == "Free tier")
        #expect(snapshot.metrics.map(\.label) == ["Today"])
    }

    @Test("OpenRouter only classifies auth invalid when both endpoints reject the key")
    func openRouterTypedAuthFailure() async {
        let provider = OpenRouterLinuxProvider(
            keySource: ClosureAPIKeySource { "bad" },
            client: OpenRouterLinuxClient(transport: FixtureTransport(results: [
                .success(HTTPResult(data: Data(), statusCode: 401)),
                .success(HTTPResult(data: Data(), statusCode: 403)),
            ]))
        )

        await #expect(throws: OpenRouterProviderError.invalidKey) { try await provider.fetch() }
        #expect(OpenRouterProviderError.invalidKey.category == .authInvalid)
        #expect(OpenRouterProviderError.connectionFailed.category == .network)
        #expect(OpenRouterProviderError.invalidResponse.category == .decoding)
        #expect(OpenRouterProviderError.requestFailed(429).category == .rateLimited)
    }

    @Test("Z.ai maps session weekly and web-search metrics with payload cadence")
    func zaiMapping() throws {
        let quota = Data(#"{"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":15,"nextResetTime":1770648402389},{"name":"TOKENS_LIMIT","unit":4,"number":3,"percentage":40},{"type":"TIME_LIMIT","currentValue":1828,"usage":4000,"nextResetTime":1770648402389}]}}"#.utf8)
        let subscription = Data(#"{"data":[{"productName":"GLM Coding Max"}]}"#.utf8)

        let snapshot = try ZAILinuxMapper.map(
            quotaBody: quota,
            subscriptionBody: subscription,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        #expect(snapshot.providerID == "zai")
        #expect(snapshot.instanceID == "zai")
        #expect(snapshot.displayName == "Z.ai")
        #expect(snapshot.accountLabel == nil)
        #expect(snapshot.plan == "GLM Coding Max")
        #expect(snapshot.metrics.map(\.label) == ["Session", "Weekly", "Web Searches"])
        #expect(snapshot.metrics.map(\.used) == [15, 40, 1828])
        #expect(snapshot.metrics.map(\.limit) == [100, 100, 4000])
        #expect(snapshot.metrics.map(\.periodDurationMilliseconds) == [18_000_000, 259_200_000, 2_592_000_000])
        #expect(snapshot.metrics[0].resetsAt?.timeIntervalSince1970 == 1_770_648_402.389)
        #expect(snapshot.links == ZAILinuxProvider.links)
        #expect(snapshot.widgets == ZAILinuxProvider.widgetDescriptors)
    }

    @Test("Z.ai validates quota fields and distinguishes no-plan accounts")
    func zaiTypedMappingFailures() {
        #expect(throws: ZAIProviderError.invalidResponse) {
            try ZAILinuxMapper.mapQuota(Data(#"{"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5}]}}"#.utf8))
        }
        #expect(throws: ZAIProviderError.invalidResponse) {
            try ZAILinuxMapper.mapQuota(Data(#"{"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":true}]}}"#.utf8))
        }
        #expect(ZAILinuxMapper.isNoCodingPlan(Data(#"{"success":false,"code":500,"msg":"no coding plan"}"#.utf8)))
        #expect(ZAIProviderError.noCodingPlan.category == .notAvailable)
    }

    @Test("Z.ai treats subscription as optional but quota as required")
    func zaiOptionalSubscription() async {
        let quota = Data(#"{"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":25}]}}"#.utf8)
        let provider = ZAILinuxProvider(
            keySource: ClosureAPIKeySource { "key" },
            client: ZAILinuxClient(transport: FixtureTransport(results: [
                .success(HTTPResult(data: quota, statusCode: 200)),
                .success(HTTPResult(data: Data(), statusCode: 500)),
            ]))
        )

        let snapshot = await provider.refresh()

        #expect(snapshot.errorMessage == nil)
        #expect(snapshot.plan == nil)
        #expect(snapshot.metrics.map(\.label) == ["Session"])
    }

    @Test("Metadata exactly matches macOS links and widget descriptors")
    func metadata() {
        #expect(OpenRouterLinuxProvider.links == [
            ProviderLink(label: "Activity", url: "https://openrouter.ai/activity"),
            ProviderLink(label: "Credits", url: "https://openrouter.ai/settings/credits"),
        ])
        #expect(OpenRouterLinuxProvider.widgetDescriptors.map(\.id) == [
            "openrouter.credits", "openrouter.balance", "openrouter.today", "openrouter.week", "openrouter.month", "openrouter.keyLimit",
        ])
        #expect(ZAILinuxProvider.links == [
            ProviderLink(label: "Dashboard", url: "https://z.ai/manage-apikey/coding-plan/personal/my-plan"),
            ProviderLink(label: "API Keys", url: "https://z.ai/manage-apikey/apikey-list"),
        ])
        #expect(ZAILinuxProvider.widgetDescriptors.map(\.id) == ["zai.session", "zai.weekly", "zai.webSearches"])
    }
}

private actor FixtureTransport: HTTPTransport {
    private var results: [Result<HTTPResult, any Error>]

    init(results: [Result<HTTPResult, any Error>]) {
        self.results = results
    }

    func execute(_ request: URLRequest) async throws -> HTTPResult {
        guard !results.isEmpty else { throw FixtureError.noResult }
        return try results.removeFirst().get()
    }
}

private enum FixtureError: Error {
    case noResult
}
