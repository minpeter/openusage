import Foundation
import Testing
@testable import OpenUsageLinuxCore

@Suite("Linux core")
struct LinuxCoreTests {
    @Test("Metric vocabulary round trips every dashboard shape")
    func metricVocabularyRoundTrips() throws {
        let metrics = [
            UsageMetric(
                kind: .values,
                label: "Today",
                used: 0,
                values: [
                    UsageValue(label: "Cost", value: 12.34, unit: .dollars),
                    UsageValue(label: "Tokens", value: 42_000, unit: .tokens),
                ]
            ),
            UsageMetric(
                kind: .badge,
                label: "Status",
                used: 0,
                text: "Enabled"
            ),
            UsageMetric(
                kind: .chart,
                label: "30 Days",
                used: 0,
                points: [
                    UsagePoint(date: Date(timeIntervalSince1970: 1_700_000_000), value: 9.5)
                ]
            ),
            UsageMetric(
                kind: .text,
                label: "Notice",
                used: 0,
                text: "Account requires attention"
            ),
        ]
        let snapshot = ProviderUsageSnapshot(
            providerID: "claude",
            instanceID: "claude:work",
            displayName: "Claude",
            accountLabel: "work@example.com",
            plan: "Team",
            metrics: metrics,
            links: [ProviderLink(label: "Console", url: "https://console.anthropic.com")],
            widgets: [WidgetDescriptor(id: "weekly", title: "Weekly", metricLabel: "Weekly")]
        )

        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ProviderUsageSnapshot.self, from: encoded)

        #expect(decoded == snapshot)
        #expect(decoded.instanceID == "claude:work")
        #expect(decoded.metrics.map(\.kind) == [.values, .badge, .chart, .text])
    }

    @Test("Provider links allow only HTTP destinations")
    func providerLinksAllowOnlyHTTPDestinations() {
        #expect(ProviderLink(label: "Console", url: "https://example.com").safeURL != nil)
        #expect(ProviderLink(label: "Status", url: "http://status.example.com").safeURL != nil)
        #expect(ProviderLink(label: "Script", url: "javascript:alert(1)").safeURL == nil)
        #expect(ProviderLink(label: "File", url: "file:///tmp/token").safeURL == nil)
        #expect(ProviderLink(label: " ", url: "https://example.com").safeURL == nil)
    }

    @Test("Legacy snapshots gain stable instance defaults")
    func legacySnapshotsGainStableDefaults() throws {
        let data = Data(
            """
            {
              "providerID":"codex",
              "displayName":"Codex",
              "plan":"Pro",
              "metrics":[],
              "refreshedAt":"2026-08-09T00:00:00Z"
            }
            """.utf8
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(ProviderUsageSnapshot.self, from: data)

        #expect(snapshot.instanceID == "codex")
        #expect(snapshot.links.isEmpty)
        #expect(snapshot.widgets.isEmpty)
    }

    @Test("XDG paths use explicit environment roots")
    func xdgPathsUseEnvironmentRoots() {
        let paths = LinuxPaths(environment: [
            "HOME": "/home/tester",
            "XDG_CONFIG_HOME": "/tmp/config",
            "XDG_CACHE_HOME": "/tmp/cache",
        ])

        #expect(paths.configDirectory.path == "/tmp/config/openusage")
        #expect(paths.cacheDirectory.path == "/tmp/cache/openusage")
        #expect(paths.claudeCredentials.path == "/home/tester/.claude/.credentials.json")
        #expect(paths.codexAuthCandidates.map(\.path) == [
            "/tmp/config/codex/auth.json",
            "/home/tester/.codex/auth.json",
        ])
    }

    @Test("Claude usage maps live quota windows")
    func claudeUsageMapsQuotaWindows() throws {
        let data = Data(
            """
            {
              "five_hour": {"utilization": 42, "resets_at": "2026-08-09T18:00:00Z"},
              "seven_day": {"utilization": 63, "resets_at": "2026-08-12T00:00:00Z"},
              "limits": [{
                "kind": "weekly_scoped",
                "scope": {"model": {"display_name": "Fable"}},
                "percent": 25,
                "resets_at": "2026-08-12T00:00:00Z"
              }],
              "extra_usage": {
                "is_enabled": true,
                "used_credits": 1250,
                "monthly_limit": 5000
              }
            }
            """.utf8
        )

        let snapshot = try ClaudeUsageMapper.map(
            data: data,
            accountLabel: "Claude Code",
            credentials: ClaudeCredentials(
                accessToken: "token",
                refreshToken: nil,
                expiresAt: nil,
                subscriptionType: "team",
                rateLimitTier: "default_5x",
                scopes: ["user:profile"]
            )
        )

        #expect(snapshot.plan == "Team 5x")
        #expect(snapshot.accountLabel == "Claude Code")
        #expect(snapshot.metrics.map(\.label) == ["Session", "Weekly", "Fable", "Extra Usage"])
        #expect(snapshot.metrics.map(\.used) == [42, 63, 25, 12.5])
        #expect(snapshot.metrics.last?.limit == 50)
    }

    @Test("Codex usage classifies windows by duration")
    func codexUsageClassifiesWindowsByDuration() throws {
        let data = Data(
            """
            {
              "plan_type": "pro",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 71,
                  "limit_window_seconds": 604800,
                  "reset_after_seconds": 3600
                },
                "secondary_window": {
                  "used_percent": 18,
                  "limit_window_seconds": 18000,
                  "reset_after_seconds": 900
                }
              },
              "credits": {"balance": 20}
            }
            """.utf8
        )

        let snapshot = try CodexUsageMapper.map(
            data: data,
            accountLabel: "developer@example.com",
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        #expect(snapshot.plan == "Pro 20x")
        #expect(snapshot.accountLabel == "developer@example.com")
        #expect(snapshot.metrics.map(\.label) == ["Session", "Weekly", "Credits"])
        #expect(snapshot.metrics.map(\.used) == [18, 71, 0.8])
        #expect(snapshot.metrics.last?.detail == "20 credits")
    }

    @Test("Provider requests carry Linux credentials")
    func providerRequestsCarryCredentials() throws {
        let claude = try UsageRequests.claude(accessToken: "claude-token")
        let codex = try UsageRequests.codex(
            credentials: CodexCredentials(
                accessToken: "codex-token",
                refreshToken: nil,
                idToken: nil,
                accountID: "account-1",
                apiKey: nil
            )
        )

        #expect(claude.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(claude.value(forHTTPHeaderField: "Authorization") == "Bearer claude-token")
        #expect(claude.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(codex.url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
        #expect(codex.value(forHTTPHeaderField: "Authorization") == "Bearer codex-token")
        #expect(codex.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "account-1")
    }

    @Test("Codex refresh request uses the desktop OAuth client")
    func codexRefreshRequestUsesDesktopClient() throws {
        let request = try UsageRequests.codexRefresh(refreshToken: "refresh token/+")
        let body = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })

        #expect(request.url?.absoluteString == "https://auth.openai.com/oauth/token")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(body.contains("grant_type=refresh_token"))
        #expect(body.contains("client_id=app_EMoamEEZ73f0CkXaXp7hrann"))
        #expect(body.contains("refresh_token=refresh%20token%2F%2B"))
    }

    @Test("Snapshot cache round trips through XDG cache")
    func snapshotCacheRoundTrips() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = LinuxPaths(environment: [
            "HOME": root.path,
            "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
            "XDG_CACHE_HOME": root.appendingPathComponent("cache").path,
        ])
        let cache = SnapshotCache(paths: paths)
        let expected = [
            ProviderUsageSnapshot(
                providerID: "codex",
                displayName: "Codex",
                plan: "Pro",
                metrics: [
                    UsageMetric(kind: .progress, label: "Weekly", used: 25, limit: 100)
                ],
                refreshedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        ]

        try cache.save(expected)

        #expect(try cache.load() == expected)
    }
}
