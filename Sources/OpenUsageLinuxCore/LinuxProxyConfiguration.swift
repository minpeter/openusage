import Foundation
import Glibc

public enum LinuxProxyScheme: String, Sendable {
    case http
    case https
    case socks5

    var defaultPort: UInt16 {
        switch self {
        case .http: 80
        case .https: 443
        case .socks5: 1_080
        }
    }
}

public enum LinuxProxyConfigurationError: Error, Equatable, LocalizedError {
    case unsupportedScheme(String)
    case missingHost
    case invalidPort
    case unsupportedComponents

    public var errorDescription: String? {
        switch self {
        case .unsupportedScheme(let scheme):
            "Unsupported proxy scheme '\(scheme)'. Use http, https, or socks5."
        case .missingHost:
            "The proxy URL must include a host."
        case .invalidPort:
            "The proxy URL contains an invalid port."
        case .unsupportedComponents:
            "The proxy URL cannot include a path, query, or fragment."
        }
    }
}

public struct LinuxProxyConfiguration: Equatable, Sendable {
    private static let loopbackBypassHosts = ["localhost", "127.0.0.1", "::1"]

    public let scheme: LinuxProxyScheme
    public let host: String
    public let port: UInt16
    public let username: String?
    public let password: String?
    public let bypassHosts: [String]
    public let url: String

    public init(
        url rawURL: String,
        bypassHosts: [String] = []
    ) throws {
        let normalized = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: normalized),
              let rawScheme = components.scheme?.lowercased()
        else {
            throw LinuxProxyConfigurationError.unsupportedScheme("")
        }
        guard let scheme = LinuxProxyScheme(rawValue: rawScheme) else {
            throw LinuxProxyConfigurationError.unsupportedScheme(rawScheme)
        }
        guard let host = components.host, !host.isEmpty else {
            throw LinuxProxyConfigurationError.missingHost
        }
        guard components.path.isEmpty || components.path == "/",
              components.query == nil,
              components.fragment == nil
        else {
            throw LinuxProxyConfigurationError.unsupportedComponents
        }
        let port: UInt16
        if let specified = components.port {
            guard let converted = UInt16(exactly: specified) else {
                throw LinuxProxyConfigurationError.invalidPort
            }
            port = converted
        } else {
            port = scheme.defaultPort
        }

        self.scheme = scheme
        self.host = host
        self.port = port
        username = components.user
        password = components.password
        self.bypassHosts = Self.effectiveBypassHosts(bypassHosts)
        url = normalized
    }

    public var processEnvironment: [String: String] {
        [
            "http_proxy": url,
            "https_proxy": url,
            "all_proxy": url,
            "HTTP_PROXY": url,
            "HTTPS_PROXY": url,
            "ALL_PROXY": url,
            "no_proxy": bypassHosts.joined(separator: ","),
            "NO_PROXY": bypassHosts.joined(separator: ","),
        ]
    }

    public func applyToProcessEnvironment() {
        for (key, value) in processEnvironment {
            setenv(key, value, 1)
        }
    }

    private static func effectiveBypassHosts(_ custom: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        let loopback = Set(loopbackBypassHosts)
        for raw in custom {
            let host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = host.lowercased()
            guard !host.isEmpty,
                  !loopback.contains(key),
                  seen.insert(key).inserted
            else {
                continue
            }
            result.append(host)
        }
        result.append(contentsOf: loopbackBypassHosts)
        return result
    }
}
