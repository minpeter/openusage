import Foundation
import Testing
@testable import OpenUsageLinuxCore

@Suite("Antigravity Secret Service")
struct AntigravitySecretServiceTests {
    @Test("Current AGY keyring token refreshes without a fallback file")
    func currentKeyringToken() async throws {
        let token = Data("""
        {"token":{"access_token":"ya29.keyring","refresh_token":"1//refresh","expiry":"2099-01-01T00:00:00Z"}}
        """.utf8)
        let username = SecretServiceAttributes(["service": "gemini", "username": "antigravity"])
        let service = AntigravitySecretServiceFixture(secret: token, matching: username)
        let provider = AntigravityLinuxProvider(
            paths: AntigravityLinuxPaths(environment: ["HOME": "/home/tester"]),
            files: AntigravityEmptyFiles(),
            client: AntigravityKeyringClient(),
            secretService: service
        )

        let snapshot = try await provider.refresh()

        #expect(snapshot.metrics.map(\.label) == ["Session"])
        #expect(service.lookups == [username])
    }

    @Test("Legacy account attribute remains a fallback")
    func legacyAccountFallback() async throws {
        let token = Data("""
        {"token":{"access_token":"ya29.legacy","expiry":"2099-01-01T00:00:00Z"}}
        """.utf8)
        let username = SecretServiceAttributes(["service": "gemini", "username": "antigravity"])
        let account = SecretServiceAttributes(["service": "gemini", "account": "antigravity"])
        let service = AntigravitySecretServiceFixture(secret: token, matching: account)
        let provider = AntigravityLinuxProvider(
            files: AntigravityEmptyFiles(),
            client: AntigravityKeyringClient(),
            secretService: service
        )

        _ = try await provider.refresh()

        #expect(service.lookups == [username, account])
    }

    @Test("A locked credential-store failure falls back to the AGY credential file")
    func lockedCredentialStoreUsesFileFallback() async throws {
        let service = AntigravitySecretServiceFixture(error: SecretServiceError.unavailable)
        let fallbackPath = "/home/tester/.gemini/antigravity-cli/antigravity-oauth-token"
        let fallback = Data(#"{"token":{"access_token":"ya29.file","expiry":"2099-01-01T00:00:00Z"}}"#.utf8)
        let provider = AntigravityLinuxProvider(
            paths: AntigravityLinuxPaths(environment: ["HOME": "/home/tester"]),
            files: AntigravityFixtureFiles([fallbackPath: fallback]),
            client: AntigravityKeyringClient(),
            secretService: service
        )

        let snapshot = try await provider.refresh()

        #expect(snapshot.metrics.map(\.label) == ["Session"])
    }

    @Test("A locked credential-store failure remains typed when no fallback file exists")
    func lockedCredentialStoreFailure() async {
        let service = AntigravitySecretServiceFixture(error: SecretServiceError.unavailable)
        let provider = AntigravityLinuxProvider(
            paths: AntigravityLinuxPaths(environment: ["HOME": "/home/tester"]),
            files: AntigravityEmptyFiles(),
            client: AntigravityKeyringClient(),
            secretService: service
        )

        await #expect(throws: AntigravityLinuxError.credentialStoreUnreadable) {
            try await provider.refresh()
        }
    }

    @Test("A malformed fallback remains invalid when the credential store is locked")
    func lockedCredentialStoreWithMalformedFile() async {
        let service = AntigravitySecretServiceFixture(error: SecretServiceError.unavailable)
        let fallbackPath = "/home/tester/.gemini/antigravity-cli/antigravity-oauth-token"
        let provider = AntigravityLinuxProvider(
            paths: AntigravityLinuxPaths(environment: ["HOME": "/home/tester"]),
            files: AntigravityFixtureFiles([fallbackPath: Data("{}".utf8)]),
            client: AntigravityKeyringClient(),
            secretService: service
        )

        await #expect(throws: AntigravityLinuxError.invalidCredentialData) {
            try await provider.refresh()
        }
    }

    @Test("Direct client rejects an oversized secret")
    func directClientSizeBoundary() {
        let maximum = BoundedProviderFileReader.defaultMaximumBytes
        let service = GIOSecretService { _ in Data(repeating: 0x41, count: maximum + 1) }

        #expect(throws: SecretServiceError.unavailable) {
            try service.lookup(attributes: .init(["service": "gemini", "username": "antigravity"]))
        }

        let atLimit = GIOSecretService.nativeCopyOutcomeForTesting(Data(repeating: 0x41, count: maximum))
        #expect(atLimit.accepted)
        #expect(atLimit.allocated)
        #expect(atLimit.length == maximum)

        let oversized = GIOSecretService.nativeCopyOutcomeForTesting(Data(repeating: 0x41, count: maximum + 1))
        #expect(!oversized.accepted)
        #expect(!oversized.allocated)
        #expect(oversized.length == 0)
    }

    @Test("Direct client maps AGY attributes to native lookup keys")
    func directClientAttributes() throws {
        let recorder = AntigravityIdentityKeyRecorder()
        let service = GIOSecretService { key in
            recorder.append(key)
            return Data("secret".utf8)
        }

        _ = try service.lookup(attributes: .init(["service": "gemini", "username": "antigravity"]))
        _ = try service.lookup(attributes: .init(["service": "gemini", "account": "antigravity"]))
        let unrelated = try service.lookup(attributes: .init(["service": "other", "username": "antigravity"]))

        #expect(recorder.values == ["username", "account"])
        #expect(unrelated == nil)
    }
}

private final class AntigravitySecretServiceFixture: FreedesktopSecretService, @unchecked Sendable {
    private let secret: Data?
    private let matching: SecretServiceAttributes?
    private let error: (any Error)?
    private(set) var lookups: [SecretServiceAttributes] = []

    init(secret: Data, matching: SecretServiceAttributes) {
        self.secret = secret
        self.matching = matching
        self.error = nil
    }

    init(error: any Error) {
        self.secret = nil
        self.matching = nil
        self.error = error
    }

    func lookup(attributes: SecretServiceAttributes) throws -> Data? {
        lookups.append(attributes)
        if let error { throw error }
        return attributes == matching ? secret : nil
    }

    func store(_ secret: Data, label: String, attributes: SecretServiceAttributes) throws {}
    func clear(attributes: SecretServiceAttributes) throws {}
}

private struct AntigravityEmptyFiles: ProviderFileReading {
    func readIfPresent(_ url: URL) throws -> Data? { nil }
}

private struct AntigravityFixtureFiles: ProviderFileReading {
    let files: [String: Data]

    init(_ files: [String: Data]) {
        self.files = files
    }

    func readIfPresent(_ url: URL) throws -> Data? {
        files[url.path]
    }
}

private struct AntigravityKeyringClient: AntigravityUsageFetching {
    func fetch(accessToken: String) async throws -> AntigravityUsagePayload {
        let summary = Data("""
        {"groups":[{"buckets":[{"bucketId":"gemini-5h","remainingFraction":0.75}]}]}
        """.utf8)
        return AntigravityUsagePayload(summary: summary, plan: nil)
    }
}

private final class AntigravityIdentityKeyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func append(_ value: String) {
        lock.withLock { storage.append(value) }
    }
}
