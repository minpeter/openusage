import Foundation

public struct ClaudeCredentials: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Double?
    public var subscriptionType: String?
    public var rateLimitTier: String?
    public var scopes: [String]?

    enum CodingKeys: String, CodingKey {
        case accessToken
        case refreshToken
        case expiresAt
        case subscriptionType
        case rateLimitTier
        case scopes
    }
}

private struct ClaudeCredentialsDocument: Codable {
    let claudeAiOauth: ClaudeCredentials?
}

public struct CodexCredentials: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var idToken: String?
    public var accountID: String?
    public var apiKey: String?
    public var lastRefresh: String?

    private enum RootKeys: String, CodingKey {
        case tokens
        case apiKey = "OPENAI_API_KEY"
        case lastRefresh = "last_refresh"
    }

    private enum TokenKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case accountID = "account_id"
    }

    public init(
        accessToken: String,
        refreshToken: String?,
        idToken: String?,
        accountID: String?,
        apiKey: String?,
        lastRefresh: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.accountID = accountID
        self.apiKey = apiKey
        self.lastRefresh = lastRefresh
    }

    public init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: RootKeys.self)
        apiKey = try root.decodeIfPresent(String.self, forKey: .apiKey)
        lastRefresh = try root.decodeIfPresent(String.self, forKey: .lastRefresh)
        if root.contains(.tokens) {
            let tokens = try root.nestedContainer(keyedBy: TokenKeys.self, forKey: .tokens)
            accessToken = try tokens.decodeIfPresent(String.self, forKey: .accessToken) ?? ""
            refreshToken = try tokens.decodeIfPresent(String.self, forKey: .refreshToken)
            idToken = try tokens.decodeIfPresent(String.self, forKey: .idToken)
            accountID = try tokens.decodeIfPresent(String.self, forKey: .accountID)
        } else {
            accessToken = ""; refreshToken = nil; idToken = nil; accountID = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var root = encoder.container(keyedBy: RootKeys.self)
        try root.encodeIfPresent(apiKey, forKey: .apiKey)
        try root.encodeIfPresent(lastRefresh, forKey: .lastRefresh)
        var tokens = root.nestedContainer(keyedBy: TokenKeys.self, forKey: .tokens)
        try tokens.encode(accessToken, forKey: .accessToken)
        try tokens.encodeIfPresent(refreshToken, forKey: .refreshToken)
        try tokens.encodeIfPresent(idToken, forKey: .idToken)
        try tokens.encodeIfPresent(accountID, forKey: .accountID)
    }

    public var accountLabel: String? {
        if let email = idToken.flatMap(Self.email) {
            return email
        }
        guard let accountID, !accountID.isEmpty else { return nil }
        return "Account …\(accountID.suffix(6))"
    }

    private static func email(fromJWT token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var encoded = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return payload["email"] as? String
    }
}

public struct LinuxCredentialStore: Sendable {
    public let paths: LinuxPaths

    public init(paths: LinuxPaths = LinuxPaths()) {
        self.paths = paths
    }

    public func loadClaude() throws -> ClaudeCredentials {
        try loadClaude(credentialsFile: paths.claudeCredentials)
    }

    public func loadClaude(configDirectory: URL) throws -> ClaudeCredentials {
        try loadClaude(credentialsFile: configDirectory.appendingPathComponent(".credentials.json"))
    }

    private func loadClaude(credentialsFile: URL) throws -> ClaudeCredentials {
        let data = try read(path: credentialsFile, provider: "Claude")
        guard let credentials = try JSONDecoder().decode(ClaudeCredentialsDocument.self, from: data).claudeAiOauth,
              !credentials.accessToken.isEmpty
        else {
            throw LinuxUsageError.invalidCredentials("Claude")
        }
        return credentials
    }

    public func saveClaude(_ credentials: ClaudeCredentials, configDirectory: URL) throws {
        let path = configDirectory.appendingPathComponent(".credentials.json")
        var object = (try? Data(contentsOf: path)).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        } ?? [:]
        let encoded = try JSONEncoder().encode(credentials)
        object["claudeAiOauth"] = try JSONSerialization.jsonObject(with: encoded)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: path, options: .atomic)
    }

    public func loadCodex() throws -> CodexCredentials {
        guard let path = paths.codexAuthCandidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else {
            throw LinuxUsageError.credentialsMissing("Codex")
        }
        let data = try read(path: path, provider: "Codex")
        let credentials = try JSONDecoder().decode(CodexCredentials.self, from: data)
        guard !credentials.accessToken.isEmpty else {
            throw LinuxUsageError.invalidCredentials("Codex")
        }
        return credentials
    }

    public func saveCodex(_ credentials: CodexCredentials) throws {
        let fileManager = FileManager.default
        let path = paths.codexAuthCandidates.first(where: {
            fileManager.fileExists(atPath: $0.path)
        }) ?? paths.codexAuthCandidates[0]
        let existing = (try? Data(contentsOf: path))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var document = existing
        var tokens = document["tokens"] as? [String: Any] ?? [:]
        tokens["access_token"] = credentials.accessToken
        tokens["refresh_token"] = credentials.refreshToken
        tokens["id_token"] = credentials.idToken
        tokens["account_id"] = credentials.accountID
        document["tokens"] = tokens
        document["last_refresh"] = credentials.lastRefresh
        if let apiKey = credentials.apiKey {
            document["OPENAI_API_KEY"] = apiKey
        }
        try fileManager.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: path, options: .atomic)
    }

    private func read(path: URL, provider: String) throws -> Data {
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw LinuxUsageError.credentialsMissing(provider)
        }
        do {
            return try Data(contentsOf: path)
        } catch {
            throw LinuxUsageError.invalidCredentials(provider)
        }
    }
}
