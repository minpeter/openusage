import CSecretService
import Foundation

public struct AntigravityTokenRefresh: Equatable, Sendable {
    public let accessToken: String
    public let expiresIn: Double

    public init(accessToken: String, expiresIn: Double) {
        self.accessToken = accessToken
        self.expiresIn = expiresIn
    }
}

public protocol AntigravityRefreshedTokenCaching: Sendable {
    func load(sourceRefreshToken: String, now: Date) async -> String?
    func store(
        _ refreshed: AntigravityTokenRefresh,
        sourceRefreshToken: String,
        now: Date
    ) async
    func discard() async
}

public actor AntigravityRefreshedTokenCache: AntigravityRefreshedTokenCaching {
    private struct CachedToken: Codable {
        let accessToken: String
        let expiresAt: Date
        let credentialFingerprint: String
    }

    private static let refreshBuffer: TimeInterval = 60
    private static let maximumBytes = 16 * 1024

    private let path: URL
    private let fileManager: FileManager

    public init(path: URL, fileManager: FileManager = .default) {
        self.path = path
        self.fileManager = fileManager
    }

    public func load(sourceRefreshToken: String, now: Date) -> String? {
        guard let fingerprint = Self.fingerprint(sourceRefreshToken) else {
            discard()
            return nil
        }
        guard let attributes = try? fileManager.attributesOfItem(atPath: path.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue <= Self.maximumBytes,
              let data = try? Data(contentsOf: path),
              let cached = try? JSONDecoder().decode(CachedToken.self, from: data),
              cached.credentialFingerprint == fingerprint,
              cached.expiresAt.timeIntervalSince(now) > Self.refreshBuffer,
              !cached.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            discard()
            return nil
        }
        return cached.accessToken
    }

    public func store(
        _ refreshed: AntigravityTokenRefresh,
        sourceRefreshToken: String,
        now: Date
    ) {
        guard let fingerprint = Self.fingerprint(sourceRefreshToken),
              !refreshed.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              refreshed.expiresIn > Self.refreshBuffer
        else {
            return
        }
        let cached = CachedToken(
            accessToken: refreshed.accessToken,
            expiresAt: now.addingTimeInterval(refreshed.expiresIn),
            credentialFingerprint: fingerprint
        )
        guard let data = try? JSONEncoder().encode(cached) else { return }
        do {
            try fileManager.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: path, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        } catch {
            try? fileManager.removeItem(at: path)
        }
    }

    public func discard() {
        try? fileManager.removeItem(at: path)
    }

    private static func fingerprint(_ refreshToken: String) -> String? {
        let token = refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }
        return token.utf8CString.withUnsafeBytes { bytes in
            guard let base = bytes.bindMemory(to: UInt8.self).baseAddress,
                  let digest = openusage_sha256_hex(base, UInt(token.utf8.count))
            else {
                return nil
            }
            defer { g_free(digest) }
            return String(cString: digest)
        }
    }
}
