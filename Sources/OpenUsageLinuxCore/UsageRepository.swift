import Foundation

/// Shared repository facade used by GTK, the CLI, and the loopback API. Concrete provider selection
/// lives here; refresh policy, stale preservation, Pi fold-ins, and concurrency stay in the registry.
public actor LinuxUsageRepository: ProviderSnapshotSource {
    private let registry: ProviderSnapshotRegistry

    public init(registry: ProviderSnapshotRegistry) { self.registry = registry }

    public init(
        credentials: LinuxCredentialStore = LinuxCredentialStore(),
        transport: any HTTPTransport = URLSessionTransport(),
        cache: SnapshotCache = SnapshotCache(),
        now: @escaping @Sendable () -> Date = Date.init,
        additionalRegistrations: [ProviderSnapshotRegistration] = [],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        credentialBackend: any LinuxCredentialBackend = SecretServiceCredentialBackend()
    ) {
        let registrations = Self.builtInRegistrations(
            credentials: credentials, transport: transport, now: now,
            environment: environment, credentialBackend: credentialBackend
        ) + additionalRegistrations
        let pi = PiLinuxUsageScanner(environment: environment)
        let claudeLocal = ClaudeLocalLogScanner(environment: environment)
        let codexLocal = CodexLocalLogScanner(environment: environment)
        let pricing = try? ModelPricing.bundled()
        var foldIns = [
            ProviderSnapshotFoldIn(providerIDs: Set(ProviderCatalog.cardEntries.map(\.id))) { snapshot in
                guard snapshot.instanceID == snapshot.providerID else { return [] }
                return try pi.scan(cardID: snapshot.providerID, now: now())
            }
        ]
        if let pricing {
            foldIns.append(ProviderSnapshotFoldIn(providerIDs: ["claude"]) { snapshot in
                guard snapshot.instanceID == snapshot.providerID,
                      let scan = try claudeLocal.scan(now: now(), pricing: pricing)
                else {
                    return []
                }
                return LocalSpendAggregator.metrics(from: scan, now: now())
            })
            foldIns.append(ProviderSnapshotFoldIn(providerIDs: ["codex"]) { snapshot in
                guard snapshot.instanceID == snapshot.providerID,
                      let scan = try codexLocal.scan(now: now(), pricing: pricing)
                else {
                    return []
                }
                return LocalSpendAggregator.metrics(from: scan, now: now())
            })
        }
        self.registry = ProviderSnapshotRegistry(
            registrations: registrations,
            knownProviderIDs: Set(ProviderCatalog.entries.map(\.id)).union(additionalRegistrations.map(\.providerID)),
            foldIns: foldIns,
            cache: cache,
            now: now
        )
    }

    public func knownProviderIDs() async -> Set<String> { await registry.knownProviderIDs() }
    public func snapshots(force: Bool) async -> [ProviderUsageSnapshot] { await registry.snapshots(force: force) }
    public func cachedSnapshots() async -> [ProviderUsageSnapshot] { await registry.cachedSnapshots() }
    public func refresh() async -> [ProviderUsageSnapshot] { await registry.snapshots(force: true) }

    private static func builtInRegistrations(
        credentials: LinuxCredentialStore,
        transport: any HTTPTransport,
        now: @escaping @Sendable () -> Date,
        environment: [String: String],
        credentialBackend: any LinuxCredentialBackend
    ) -> [ProviderSnapshotRegistration] {
        let providerTransport = HTTPTransportProviderAdapter(transport)
        let codex = CodexProviderClient(transport: providerTransport, now: now)
        let cursor = CursorLinuxProvider(
            credentials: CursorLinuxCredentialStore(environment: environment), transport: transport, now: now
        )
        let copilot = CopilotLinuxProvider(
            credentials: CopilotLinuxCredentialStore(environment: environment), transport: transport, now: now
        )
        let antigravity = AntigravityLinuxProvider(
            paths: AntigravityLinuxPaths(environment: environment),
            client: AntigravityCloudCodeClient(transport: transport), now: now
        )
        let devin = DevinLinuxProvider(
            credentials: DevinLinuxCredentialStore(environment: environment),
            client: DevinLinuxClient(transport: transport)
        )
        let grok = GrokLinuxProvider(
            credentials: GrokLinuxCredentialStore(environment: environment),
            client: GrokLinuxClient(transport: transport),
            scanner: GrokLinuxLogScanner(environment: environment)
        )
        let openCodePaths = OpenCodeLinuxPaths(environment: environment)
        let openCode = OpenCodeLinuxProvider(
            paths: openCodePaths,
            scanner: OpenCodeLocalScanner(databasePaths: { try openCodePaths.databaseFiles() }),
            now: now
        )
        let openRouter = OpenRouterLinuxProvider(
            keySource: OpenRouterLinuxProvider.defaultKeySource(
                secretService: optionalSecretSource(providerID: "openrouter", backend: credentialBackend),
                environment: environment
            ),
            client: OpenRouterLinuxClient(transport: transport), now: now
        )
        let zai = ZAILinuxProvider(
            keySource: ZAILinuxProvider.defaultKeySource(
                secretService: optionalSecretSource(providerID: "zai", backend: credentialBackend),
                environment: environment
            ),
            client: ZAILinuxClient(transport: transport), now: now
        )

        var registrations = claudeRegistrations(
            credentials: credentials, transport: providerTransport, now: now
        )
        registrations += [
            ProviderSnapshotRegistration(
                providerID: "codex", displayName: "Codex",
                links: ProviderDefinitions.codexLinks, widgets: ProviderDefinitions.codexWidgets
            ) {
                try await codex.refresh(credentials: credentials.loadCodex(), store: credentials)
            },
            ProviderSnapshotRegistration(
                providerID: "cursor", displayName: "Cursor",
                links: CursorLinuxProvider.links, widgets: CursorLinuxProvider.widgets
            ) { try await cursor.refresh() },
            ProviderSnapshotRegistration(
                providerID: "copilot", displayName: "GitHub Copilot",
                links: CopilotLinuxProvider.links, widgets: CopilotLinuxProvider.widgets
            ) { try await copilot.refresh() },
            ProviderSnapshotRegistration(
                providerID: "antigravity", displayName: "Antigravity",
                links: AntigravityLinuxProvider.links, widgets: AntigravityLinuxProvider.widgets
            ) { try await antigravity.refresh() },
            ProviderSnapshotRegistration(
                providerID: "opencode", displayName: "OpenCode",
                links: OpenCodeLinuxProvider.links, widgets: OpenCodeLinuxProvider.widgets
            ) { try await openCode.refresh() },
            ProviderSnapshotRegistration(
                providerID: "openrouter", displayName: "OpenRouter",
                links: OpenRouterLinuxProvider.links, widgets: OpenRouterLinuxProvider.widgetDescriptors
            ) { try await openRouter.fetch() },
            ProviderSnapshotRegistration(
                providerID: "grok", displayName: "Grok",
                links: GrokLinuxProvider.links, widgets: GrokLinuxProvider.widgetDescriptors
            ) { try await grok.refresh(now: now()) },
            ProviderSnapshotRegistration(
                providerID: "zai", displayName: "Z.ai",
                links: ZAILinuxProvider.links, widgets: ZAILinuxProvider.widgetDescriptors
            ) { try await zai.fetch() },
            ProviderSnapshotRegistration(
                providerID: "devin", displayName: "Devin",
                links: DevinLinuxProvider.links, widgets: DevinLinuxProvider.widgetDescriptors
            ) { try await devin.refresh(now: now()) },
        ]
        return registrations
    }

    private static func claudeRegistrations(
        credentials: LinuxCredentialStore,
        transport: any ProviderHTTPTransport,
        now: @escaping @Sendable () -> Date
    ) -> [ProviderSnapshotRegistration] {
        let paths = credentials.paths
        let primary = paths.claudeCredentials.deletingLastPathComponent().standardizedFileURL
        var accounts: [(directory: URL, instanceID: String, label: String?)] = [(primary, "claude", nil)]
        var seen = Set([primary.resolvingSymlinksInPath().path])

        for directory in paths.claudeConfigDirectories {
            let canonical = directory.resolvingSymlinksInPath().standardizedFileURL.path
            guard seen.insert(canonical).inserted,
                  FileManager.default.fileExists(atPath: directory.appendingPathComponent(".credentials.json").path)
            else { continue }
            accounts.append((directory, "claude@\(stableProviderIdentity(canonical))", nil))
        }
        for account in ClaudeConfigDirDiscovery(paths: paths).discover() {
            let canonical = account.configDirectory.resolvingSymlinksInPath().standardizedFileURL.path
            guard seen.insert(canonical).inserted else { continue }
            accounts.append((account.configDirectory, account.instanceID, account.accountLabel))
        }

        return accounts.sorted {
            if $0.instanceID == "claude" { return true }
            if $1.instanceID == "claude" { return false }
            return $0.instanceID < $1.instanceID
        }.map { account in
            let client = ClaudeProviderClient(transport: transport, now: now)
            let name = account.instanceID == "claude" ? "Claude" : "Claude (\(account.label ?? "Account"))"
            return ProviderSnapshotRegistration(
                providerID: "claude", instanceID: account.instanceID, displayName: name,
                links: ProviderDefinitions.claudeLinks,
                widgets: ProviderDefinitions.claudeWidgets(instanceID: account.instanceID)
            ) {
                try await client.refresh(
                    configDirectory: account.directory, store: credentials,
                    instanceID: account.instanceID, displayName: name, accountLabel: account.label
                )
            }
        }
    }

    /// Secret Service is an optional discovery source; an unavailable desktop service must not block
    /// bounded config-file and environment discovery that follows it.
    private static func optionalSecretSource(
        providerID: String,
        backend: any LinuxCredentialBackend
    ) -> ClosureAPIKeySource {
        ClosureAPIKeySource { () throws -> String? in
            let key = LinuxCredentialKey(
                instance: LinuxProviderInstanceID(providerID: providerID), kind: "api-key"
            )
            let data: Data?
            do { data = try backend.load(for: key) }
            catch { return nil }
            return data.flatMap { String(data: $0, encoding: .utf8) }
        }
    }
}
