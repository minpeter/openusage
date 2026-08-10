import CSecretService
import Foundation
import Glibc

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
        let reader = BoundedProviderFileReader(maximumBytes: Self.maximumBytes)
        guard let data = try? reader.readIfPresent(path, validating: { metadata in
            metadata.st_mode & mode_t(0o777) == mode_t(0o600) && metadata.st_uid == getuid()
        }),
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
            try PrivateAtomicFileWriter.write(data, to: path, fileManager: fileManager)
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
