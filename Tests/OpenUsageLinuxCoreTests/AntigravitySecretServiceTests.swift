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
    private let secret: Data
    private let matching: SecretServiceAttributes
    private(set) var lookups: [SecretServiceAttributes] = []

    init(secret: Data, matching: SecretServiceAttributes) {
        self.secret = secret
        self.matching = matching
    }

    func lookup(attributes: SecretServiceAttributes) throws -> Data? {
        lookups.append(attributes)
        return attributes == matching ? secret : nil
    }

    func store(_ secret: Data, label: String, attributes: SecretServiceAttributes) throws {}
    func clear(attributes: SecretServiceAttributes) throws {}
}

private struct AntigravityEmptyFiles: ProviderFileReading {
    func readIfPresent(_ url: URL) throws -> Data? { nil }
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
