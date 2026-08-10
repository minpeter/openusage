import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AntigravityLinuxPaths: Equatable, Sendable {
    public let credentialCandidates: [URL]
    public let refreshedTokenCache: URL

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let home = URL(fileURLWithPath: environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path)
        let data = URL(fileURLWithPath: environment["XDG_DATA_HOME"] ?? home.appendingPathComponent(".local/share").path)
        let config = URL(fileURLWithPath: environment["XDG_CONFIG_HOME"] ?? home.appendingPathComponent(".config").path)
        let cache = URL(fileURLWithPath: environment["XDG_CACHE_HOME"] ?? home.appendingPathComponent(".cache").path)
        var candidates: [URL] = []
        if let override = environment["ANTIGRAVITY_CREDENTIALS_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            candidates.append(URL(fileURLWithPath: Self.expandHome(override, home: home)))
        }
        candidates += [
            home.appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token"),
            data.appendingPathComponent("agy/auth.json"),
            config.appendingPathComponent("agy/auth.json"),
            home.appendingPathComponent(".local/share/agy/auth.json"),
            home.appendingPathComponent(".config/agy/auth.json"),
        ]
        var seen = Set<String>()
        credentialCandidates = candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
        refreshedTokenCache = cache
            .appendingPathComponent("openusage", isDirectory: true)
            .appendingPathComponent("antigravity-token.json")
    }

    private static func expandHome(_ path: String, home: URL) -> String {
        if path == "~" { return home.path }
        if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))).path }
        return path
    }
}

public enum AntigravityLinuxError: Error, LocalizedError, Equatable, Sendable {
    case notSignedIn
    case credentialStoreUnreadable
    case invalidCredentialData
    case authExpired
    case unavailable
    case responseTooLarge(maximumBytes: Int)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            "Start Antigravity or run `agy` and try again."
        case .credentialStoreUnreadable:
            "Couldn't read Antigravity credentials. Check file permissions or sign in again."
        case .invalidCredentialData:
            "Antigravity credentials are invalid. Open Antigravity or run `agy` to sign in again."
        case .authExpired:
            "Antigravity sign-in expired. Open Antigravity or run `agy` to refresh."
        case .unavailable:
            "Antigravity usage is temporarily unavailable. Try again shortly."
        case .responseTooLarge:
            "Antigravity returned an unexpectedly large usage response."
        }
    }
}

public struct AntigravityUsagePayload: Sendable {
    public let summary: Data
    public let plan: String?

    public init(summary: Data, plan: String?) {
        self.summary = summary
        self.plan = plan
    }
}

public protocol AntigravityUsageFetching: Sendable {
    func fetch(accessToken: String) async throws -> AntigravityUsagePayload
    func refreshAccessToken(refreshToken: String) async throws -> AntigravityTokenRefresh
}

public extension AntigravityUsageFetching {
    func refreshAccessToken(refreshToken: String) async throws -> AntigravityTokenRefresh {
        throw AntigravityLinuxError.authExpired
    }
}

public struct AntigravityLinuxProvider: Sendable {
    public static let links: [ProviderLink] = []
    public static let widgets = [
        WidgetDescriptor(id: "antigravity.geminiPro", title: "Session", metricLabel: "Session"),
        WidgetDescriptor(id: "antigravity.geminiWeekly", title: "Weekly", metricLabel: "Weekly"),
        WidgetDescriptor(id: "antigravity.claude", title: "Claude", metricLabel: "Claude"),
        WidgetDescriptor(id: "antigravity.claudeWeekly", title: "Claude Weekly", metricLabel: "Claude Weekly"),
    ]

    private let paths: AntigravityLinuxPaths
    private let files: any ProviderFileReading
    private let client: any AntigravityUsageFetching
    private let secretService: (any FreedesktopSecretService)?
    private let tokenCache: any AntigravityRefreshedTokenCaching
    private let now: @Sendable () -> Date

    public init(
        paths: AntigravityLinuxPaths = AntigravityLinuxPaths(),
        files: any ProviderFileReading = BoundedProviderFileReader(),
        client: any AntigravityUsageFetching = AntigravityCloudCodeClient(),
        secretService: (any FreedesktopSecretService)? = nil,
        tokenCache: (any AntigravityRefreshedTokenCaching)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.paths = paths
        self.files = files
        self.client = client
        self.secretService = secretService
        self.tokenCache = tokenCache ?? AntigravityRefreshedTokenCache(path: paths.refreshedTokenCache)
        self.now = now
    }

    public func hasLocalCredentials() -> Bool {
        (try? loadSecretServiceData()) != nil
            || paths.credentialCandidates.contains { (try? files.readIfPresent($0)) != nil }
    }

    public func refresh() async throws -> ProviderUsageSnapshot {
        let credential = try loadCredential()
        var tokens: [String] = []
        if let accessToken = credential.accessToken,
           credential.expiry.map({ $0.timeIntervalSince(now()) > 60 }) != false {
            tokens.append(accessToken)
        }
        if let refresh = credential.refreshToken,
           let cached = await tokenCache.load(sourceRefreshToken: refresh, now: now()),
           !tokens.contains(cached) {
            tokens.append(cached)
        }

        var payload: AntigravityUsagePayload?
        for token in tokens {
            do {
                payload = try await client.fetch(accessToken: token)
                break
            } catch AntigravityLinuxError.authExpired {
                continue
            }
        }
        if payload == nil {
            guard let refresh = credential.refreshToken else { throw AntigravityLinuxError.authExpired }
            await tokenCache.discard()
            let refreshed = try await client.refreshAccessToken(refreshToken: refresh)
            await tokenCache.store(refreshed, sourceRefreshToken: refresh, now: now())
            payload = try await client.fetch(accessToken: refreshed.accessToken)
        }
        guard let payload else { throw AntigravityLinuxError.unavailable }
        guard let metrics = AntigravityLinuxUsageMapper.metrics(from: payload.summary) else {
            throw AntigravityLinuxError.unavailable
        }
        return ProviderUsageSnapshot(
            providerID: "antigravity", displayName: "Antigravity",
            accountLabel: credential.accountLabel,
            plan: AntigravityLinuxUsageMapper.formatPlan(payload.plan), metrics: metrics,
            links: Self.links, widgets: Self.widgets, refreshedAt: now()
        )
    }

    private func loadCredential() throws -> Credential {
        let secretData: Data?
        do { secretData = try loadSecretServiceData() }
        catch { throw AntigravityLinuxError.credentialStoreUnreadable }
        if let data = secretData {
            guard let credential = Credential(data: data) else {
                throw AntigravityLinuxError.invalidCredentialData
            }
            return credential
        }
        for path in paths.credentialCandidates {
            let data: Data?
            do { data = try files.readIfPresent(path) }
            catch { throw AntigravityLinuxError.credentialStoreUnreadable }
            guard let data else { continue }
            guard let credential = Credential(data: data) else { throw AntigravityLinuxError.invalidCredentialData }
            return credential
        }
        throw AntigravityLinuxError.notSignedIn
    }

    private func loadSecretServiceData() throws -> Data? {
        guard let secretService else { return nil }
        let candidates = [
            SecretServiceAttributes(["service": "gemini", "username": "antigravity"]),
            SecretServiceAttributes(["service": "gemini", "account": "antigravity"]),
        ]
        for attributes in candidates {
            if let data = try secretService.lookup(attributes: attributes) {
                return data
            }
        }
        return nil
    }

    private struct Credential {
        let accessToken: String?
        let refreshToken: String?
        let expiry: Date?
        let accountLabel: String?

        init?(data: Data) {
            let normalized: Data
            if let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               raw.hasPrefix("go-keyring-base64:"),
               let decoded = Data(base64Encoded: String(raw.dropFirst("go-keyring-base64:".count))) {
                normalized = decoded
            } else {
                normalized = data
            }
            guard let root = try? JSONSerialization.jsonObject(with: normalized) as? [String: Any],
                  let source = Self.tokenObject(root) else { return nil }
            let access = Self.string(source, ["access_token", "accessToken", "token"])
            let refresh = Self.string(source, ["refresh_token", "refreshToken"])
            guard access != nil || refresh != nil else { return nil }
            accessToken = access
            refreshToken = refresh
            expiry = Self.string(source, ["expiry", "expires_at", "expiresAt"]).flatMap(AntigravityLinuxUsageMapper.isoDate)
            accountLabel = Self.string(source, ["email", "account", "account_email"])
                ?? Self.string(source, ["id_token", "idToken"]).flatMap(Self.jwtEmail)
                ?? access.flatMap(Self.jwtEmail)
        }

        private static func tokenObject(_ object: [String: Any]) -> [String: Any]? {
            let source = (object["token"] as? [String: Any]) ?? object
            if string(source, ["access_token", "accessToken", "token", "refresh_token", "refreshToken"]) != nil { return source }
            for key in ["tokens", "oauth", "oauth2", "credentials", "auth"] {
                if let nested = object[key] as? [String: Any], let found = tokenObject(nested) { return found }
            }
            return nil
        }

        private static func string(_ object: [String: Any], _ keys: [String]) -> String? {
            keys.lazy.compactMap { (object[$0] as? String)?.antigravityTrimmedNonEmpty }.first
        }

        private static func jwtEmail(_ token: String) -> String? {
            let pieces = token.split(separator: ".", omittingEmptySubsequences: false)
            guard pieces.count > 1 else { return nil }
            var encoded = String(pieces[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
            guard let data = Data(base64Encoded: encoded),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return (payload["email"] as? String)?.antigravityTrimmedNonEmpty
        }
    }
}

extension String {
    var antigravityTrimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
