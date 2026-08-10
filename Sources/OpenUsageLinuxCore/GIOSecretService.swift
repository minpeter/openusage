import CSecretService
import Foundation

/// Direct org.freedesktop.secrets client. Unlike libsecret's Flatpak backend, this does not redirect
/// lookups through the per-application Secret portal.
public struct GIOSecretService: FreedesktopSecretService {
    typealias Loader = @Sendable (String) throws -> Data?

    private let loader: Loader

    public init() {
        loader = Self.load(identityKey:)
    }

    init(loader: @escaping Loader) {
        self.loader = loader
    }

    public func lookup(attributes: SecretServiceAttributes) throws -> Data? {
        guard attributes.values["service"] == "gemini" else { return nil }
        let data: Data?
        if attributes.values["username"] == "antigravity" {
            data = try loader("username")
        } else if attributes.values["account"] == "antigravity" {
            data = try loader("account")
        } else {
            return nil
        }
        guard data?.count ?? 0 <= BoundedProviderFileReader.defaultMaximumBytes else {
            throw SecretServiceError.unavailable
        }
        return data
    }

    public func store(_ secret: Data, label: String, attributes: SecretServiceAttributes) throws {
        throw SecretServiceError.unavailable
    }

    public func clear(attributes: SecretServiceAttributes) throws {
        throw SecretServiceError.unavailable
    }

    static func nativeCopyOutcomeForTesting(_ secret: Data) -> (accepted: Bool, allocated: Bool, length: Int) {
        var result = OpenUsageSecretResult()
        defer { openusage_secret_result_clear(&result) }
        let accepted = secret.withUnsafeBytes { buffer in
            openusage_secret_result_copy_bytes(
                buffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                UInt(buffer.count),
                &result
            ) != 0
        }
        return (accepted, result.bytes != nil, Int(result.length))
    }

    private static func load(identityKey: String) throws -> Data? {
        var result = OpenUsageSecretResult()
        defer { openusage_secret_result_clear(&result) }
        guard openusage_secret_service_lookup(identityKey, &result) != 0 else {
            throw SecretServiceError.unavailable
        }
        guard result.length <= BoundedProviderFileReader.defaultMaximumBytes else {
            throw SecretServiceError.unavailable
        }
        guard let bytes = result.bytes, result.length > 0 else { return nil }
        return Data(bytes: bytes, count: Int(result.length))
    }
}
