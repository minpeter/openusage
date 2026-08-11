import Foundation

public struct LinuxCredentialKey: Hashable, Sendable {
    public let instance: LinuxProviderInstanceID
    public let kind: String

    public init(instance: LinuxProviderInstanceID, kind: String) {
        self.instance = instance
        self.kind = kind
    }
}

public protocol LinuxCredentialBackend: Sendable {
    func load(for key: LinuxCredentialKey) throws -> Data?
    func store(_ secret: Data, for key: LinuxCredentialKey) throws
    func remove(_ key: LinuxCredentialKey) throws
}

public struct SecretServiceAttributes: Equatable, Sendable {
    public let values: [String: String]

    public init(_ values: [String: String]) { self.values = values }

    fileprivate var commandArguments: [String] {
        values.keys.sorted().flatMap { [$0, values[$0]!] }
    }
}

/// Freedesktop Secret Service boundary. A DBus-native client or `secret-tool` can conform without
/// leaking transport details into providers.
public protocol FreedesktopSecretService: Sendable {
    func lookup(attributes: SecretServiceAttributes) throws -> Data?
    func store(_ secret: Data, label: String, attributes: SecretServiceAttributes) throws
    func clear(attributes: SecretServiceAttributes) throws
}

public enum SecretServiceError: Error, Equatable, LocalizedError {
    case unavailable
    case commandFailed(operation: String, status: Int32)

    public var errorDescription: String? {
        switch self {
        case .unavailable: "Freedesktop Secret Service is unavailable"
        case .commandFailed(let operation, let status):
            "Freedesktop Secret Service \(operation) failed with status \(status)"
        }
    }
}

/// `secret-tool` adapter for org.freedesktop.secrets. Secret bytes are sent through stdin and are
/// never included in arguments, labels, attributes, or error values.
public struct SecretToolService: FreedesktopSecretService {
    private let runner: any CommandRunning
    public let executableURL: URL

    public init(
        runner: any CommandRunning = BoundedCommandRunner(),
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/secret-tool")
    ) {
        self.runner = runner
        self.executableURL = executableURL
    }

    public func attributes(for key: LinuxCredentialKey) -> SecretServiceAttributes {
        SecretServiceAttributes([
            "application": "io.github.minpeter.OpenUsage",
            "provider": key.instance.providerID,
            "instance": key.instance.rawValue,
            "account": key.instance.accountInstanceID ?? "default",
            "kind": key.kind,
        ])
    }

    public func lookup(attributes: SecretServiceAttributes) throws -> Data? {
        let result = try runner.run(CommandInvocation(
            executableURL: executableURL,
            arguments: ["lookup"] + attributes.commandArguments
        ))
        if result.status == 1 { return nil }
        guard result.status == 0 else {
            throw SecretServiceError.commandFailed(operation: "lookup", status: result.status)
        }
        var secret = result.standardOutput
        if secret.last == 0x0A { secret.removeLast() }
        return secret.isEmpty ? nil : secret
    }

    public func store(_ secret: Data, label: String, attributes: SecretServiceAttributes) throws {
        let result = try runner.run(CommandInvocation(
            executableURL: executableURL,
            arguments: ["store", "--label", label] + attributes.commandArguments,
            standardInput: secret
        ))
        guard result.status == 0 else {
            throw SecretServiceError.commandFailed(operation: "store", status: result.status)
        }
    }

    public func clear(attributes: SecretServiceAttributes) throws {
        let result = try runner.run(CommandInvocation(
            executableURL: executableURL,
            arguments: ["clear"] + attributes.commandArguments
        ))
        guard result.status == 0 || result.status == 1 else {
            throw SecretServiceError.commandFailed(operation: "clear", status: result.status)
        }
    }
}

public struct SecretServiceCredentialBackend: LinuxCredentialBackend {
    private let service: any FreedesktopSecretService

    public init(service: any FreedesktopSecretService = SecretToolService()) {
        self.service = service
    }

    public func load(for key: LinuxCredentialKey) throws -> Data? {
        try service.lookup(attributes: attributes(for: key))
    }

    public func store(_ secret: Data, for key: LinuxCredentialKey) throws {
        try service.store(
            secret,
            label: "OpenUsage \(key.instance.providerID) \(key.kind)",
            attributes: attributes(for: key)
        )
    }

    public func remove(_ key: LinuxCredentialKey) throws {
        try service.clear(attributes: attributes(for: key))
    }

    private func attributes(for key: LinuxCredentialKey) -> SecretServiceAttributes {
        SecretServiceAttributes([
            "application": "io.github.minpeter.OpenUsage",
            "provider": key.instance.providerID,
            "instance": key.instance.rawValue,
            "account": key.instance.accountInstanceID ?? "default",
            "kind": key.kind,
        ])
    }
}

/// Adapts one typed credential to providers that consume `ProviderAPIKeySource`.
public struct SecretServiceAPIKeySource: ProviderAPIKeySource {
    private let backend: any LinuxCredentialBackend
    private let key: LinuxCredentialKey

    public init(backend: any LinuxCredentialBackend, key: LinuxCredentialKey) {
        self.backend = backend
        self.key = key
    }

    public func loadAPIKey() throws -> String? {
        guard let data = try backend.load(for: key),
              let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }
}

public enum ManagedAPIKeyProvider: String, CaseIterable, Hashable, Sendable {
    case openRouter
    case zai

    public var providerID: String {
        switch self {
        case .openRouter: "openrouter"
        case .zai: "zai"
        }
    }

    public var displayName: String {
        switch self {
        case .openRouter: "OpenRouter"
        case .zai: "Z.ai"
        }
    }

    public var credentialKey: LinuxCredentialKey {
        LinuxCredentialKey(
            instance: LinuxProviderInstanceID(providerID: providerID),
            kind: "api-key"
        )
    }
}

public enum LinuxAPIKeyManagementError: Error, Equatable, LocalizedError {
    case emptyKey
    case keyTooLarge(maximumBytes: Int)

    public var errorDescription: String? {
        switch self {
        case .emptyKey:
            "API keys cannot be blank."
        case .keyTooLarge(let maximumBytes):
            "API keys cannot exceed \(maximumBytes) bytes."
        }
    }
}

public struct LinuxAPIKeyManager: Sendable {
    public static let maximumBytes = 8_192
    private let backend: any LinuxCredentialBackend

    public init(
        backend: any LinuxCredentialBackend = SecretServiceCredentialBackend()
    ) {
        self.backend = backend
    }

    public func load(for provider: ManagedAPIKeyProvider) throws -> String? {
        guard let data = try backend.load(for: provider.credentialKey),
              let value = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }
        return value
    }

    public func hasStoredKey(for provider: ManagedAPIKeyProvider) throws -> Bool {
        try load(for: provider) != nil
    }

    public func store(
        _ value: String,
        for provider: ManagedAPIKeyProvider
    ) throws {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw LinuxAPIKeyManagementError.emptyKey
        }
        let data = Data(normalized.utf8)
        guard data.count <= Self.maximumBytes else {
            throw LinuxAPIKeyManagementError.keyTooLarge(
                maximumBytes: Self.maximumBytes
            )
        }
        try backend.store(data, for: provider.credentialKey)
    }

    public func clear(_ provider: ManagedAPIKeyProvider) throws {
        try backend.remove(provider.credentialKey)
    }
}
