import Foundation

/// Synchronous lookup boundary for provider API keys. A Secret Service implementation can conform
/// without changing provider code; `ClosureAPIKeySource` is the adapter used while that integration
/// is supplied by the application layer.
public protocol ProviderAPIKeySource: Sendable {
    func loadAPIKey() throws -> String?
}

public struct ClosureAPIKeySource: ProviderAPIKeySource {
    private let loader: @Sendable () throws -> String?

    public init(loader: @escaping @Sendable () throws -> String?) {
        self.loader = loader
    }

    public func loadAPIKey() throws -> String? {
        try loader().flatMap(Self.normalized)
    }

    private static func normalized(_ value: String) -> String? {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }
}

public struct EnvironmentAPIKeySource: ProviderAPIKeySource {
    public let names: [String]
    private let environment: [String: String]

    public init(names: [String], environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.names = names
        self.environment = environment
    }

    public func loadAPIKey() -> String? {
        for name in names {
            if let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

public struct FileAPIKeySource: ProviderAPIKeySource {
    public let urls: [URL]

    public init(urls: [URL]) {
        self.urls = urls
    }

    public func loadAPIKey() throws -> String? {
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            let raw = try String(contentsOf: url, encoding: .utf8)
            if let key = Self.parse(raw) { return key }
        }
        return nil
    }

    private static func parse(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            for name in ["apiKey", "api_key", "key"] {
                if let value = object[name] as? String {
                    let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !key.isEmpty { return key }
                }
            }
            return nil
        }
        return trimmed
    }
}

public struct CompositeAPIKeySource: ProviderAPIKeySource {
    private let sources: [any ProviderAPIKeySource]

    public init(sources: [any ProviderAPIKeySource]) {
        self.sources = sources
    }

    public func loadAPIKey() throws -> String? {
        for source in sources {
            if let key = try source.loadAPIKey() { return key }
        }
        return nil
    }
}

public enum ProviderErrorCategory: String, Codable, Equatable, Sendable {
    case notLoggedIn = "not_logged_in"
    case authInvalid = "auth_invalid"
    case credentialAccess = "credential_access"
    case network
    case decoding
    case http4xx = "http_4xx"
    case http5xx = "http_5xx"
    case rateLimited = "rate_limited"
    case notAvailable = "not_available"
    case other

    static func http(_ statusCode: Int) -> ProviderErrorCategory {
        switch statusCode {
        case 429: .rateLimited
        case 400..<500: .http4xx
        case 500..<600: .http5xx
        default: .other
        }
    }
}
