import Foundation

public struct GrokCredential: Equatable, Sendable {
    public let entryKey: String
    public var accessToken: String
    public var refreshToken: String?
    public var idToken: String?
    public var expiresAt: Date?
    public var clientID: String

    public var accountLabel: String? { idToken.flatMap(grokJWTEmail) }
    public var instanceID: String { "grok:\(stableProviderIdentity(entryKey))" }
}

public struct GrokLinuxCredentialStore: Sendable {
    public static let maximumReadBytes = 512 * 1024
    public static let defaultClientID = "b1a00492-073a-47ea-816f-4c329264a828"
    public let authURL: URL

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let home = environment["HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        self.authURL = home.appendingPathComponent(".grok/auth.json")
    }

    public func loadCandidates() throws -> [GrokCredential] {
        guard FileManager.default.fileExists(atPath: authURL.path) else { throw GrokLinuxError.notLoggedIn }
        let data: Data
        do { data = try grokReadBounded(authURL, maximumBytes: Self.maximumReadBytes) }
        catch GrokLinuxError.localDataTooLarge { throw GrokLinuxError.localDataTooLarge }
        catch { throw GrokLinuxError.invalidAuth }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GrokLinuxError.invalidAuth
        }
        let candidates = root.keys.sorted().compactMap { key -> GrokCredential? in
            guard let entry = root[key] as? [String: Any],
                  let accessToken = grokTrimmed(entry["key"] as? String)
            else { return nil }
            let explicitClient = grokTrimmed(entry["oidc_client_id"] as? String)
            let suffix = grokTrimmed(key.split(separator: "::", omittingEmptySubsequences: false).last.map(String.init))
            return GrokCredential(
                entryKey: key,
                accessToken: accessToken,
                refreshToken: grokTrimmed(entry["refresh_token"] as? String) ?? grokTrimmed(entry["refresh"] as? String),
                idToken: grokTrimmed(entry["id_token"] as? String),
                expiresAt: grokDate(entry["expires_at"] as? String) ?? grokDate(entry["expires"] as? String),
                clientID: explicitClient ?? suffix ?? Self.defaultClientID
            )
        }
        guard !candidates.isEmpty else { throw GrokLinuxError.invalidAuth }
        return candidates
    }

    public func saveRotated(_ credential: GrokCredential) throws {
        let existing: [String: Any]
        if FileManager.default.fileExists(atPath: authURL.path) {
            let data = try grokReadBounded(authURL, maximumBytes: Self.maximumReadBytes)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw GrokLinuxError.invalidAuth
            }
            existing = object
        } else {
            existing = [:]
        }
        var root = existing
        var entry = root[credential.entryKey] as? [String: Any] ?? [:]
        entry["key"] = credential.accessToken
        if let refreshToken = credential.refreshToken { entry["refresh_token"] = refreshToken }
        if let idToken = credential.idToken { entry["id_token"] = idToken }
        if let expiresAt = credential.expiresAt { entry["expires_at"] = grokISO8601String(expiresAt) }
        root[credential.entryKey] = entry
        guard JSONSerialization.isValidJSONObject(root) else { throw GrokLinuxError.invalidAuth }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        guard data.count <= Self.maximumReadBytes else { throw GrokLinuxError.localDataTooLarge }
        try FileManager.default.createDirectory(at: authURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: authURL, options: .atomic)
    }
}

func grokReadBounded(_ url: URL, maximumBytes: Int) throws -> Data {
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard values.isRegularFile == true else { throw GrokLinuxError.invalidAuth }
    guard (values.fileSize ?? maximumBytes + 1) <= maximumBytes else { throw GrokLinuxError.localDataTooLarge }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
    guard data.count <= maximumBytes else { throw GrokLinuxError.localDataTooLarge }
    return data
}

func grokTrimmed(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    return value
}

func grokDate(_ value: String?) -> Date? {
    guard let value = grokTrimmed(value) else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
}

private func grokISO8601String(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private func grokJWTObject(_ token: String) -> [String: Any]? {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count > 1 else { return nil }
    var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
    guard let data = Data(base64Encoded: payload) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

func grokJWTEmail(_ token: String) -> String? { grokTrimmed(grokJWTObject(token)?["email"] as? String) }
func grokJWTExpiry(_ token: String) -> Date? { linuxNumber(grokJWTObject(token)?["exp"]).map(Date.init(timeIntervalSince1970:)) }
