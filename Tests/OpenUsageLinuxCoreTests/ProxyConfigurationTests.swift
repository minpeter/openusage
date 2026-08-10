import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(Linux)
import Glibc
#endif
import Testing
@testable import OpenUsageLinuxCore

@Suite("Linux proxy configuration", .serialized)
struct ProxyConfigurationTests {
    @Test("HTTP HTTPS and SOCKS proxy URLs parse with deterministic defaults")
    func parsesSupportedSchemes() throws {
        let http = try LinuxProxyConfiguration(
            url: "http://user:pass@proxy.example.com",
            bypassHosts: []
        )
        let https = try LinuxProxyConfiguration(
            url: "https://secure-proxy.example.com",
            bypassHosts: []
        )
        let socks = try LinuxProxyConfiguration(
            url: "socks5://127.0.0.1:10808",
            bypassHosts: []
        )

        #expect(http.scheme == .http)
        #expect(http.port == 80)
        #expect(http.username == "user")
        #expect(http.password == "pass")
        #expect(https.scheme == .https)
        #expect(https.port == 443)
        #expect(socks.scheme == .socks5)
        #expect(socks.port == 10_808)
    }

    @Test("Transport settings always bypass loopback and normalize custom exclusions")
    func normalizesExclusions() throws {
        let proxy = try LinuxProxyConfiguration(
            url: "http://proxy.example.com:8080",
            bypassHosts: [" internal.example.com ", "LOCALHOST", "internal.example.com"]
        )
        #expect(proxy.processEnvironment["http_proxy"] == "http://proxy.example.com:8080")
        #expect(proxy.processEnvironment["https_proxy"] == "http://proxy.example.com:8080")
        #expect(proxy.processEnvironment["no_proxy"] ==
            "internal.example.com,localhost,127.0.0.1,::1")
    }

    @Test("Malformed and unsupported proxy URLs fail at the settings boundary")
    func rejectsMalformedURLs() {
        #expect(throws: LinuxProxyConfigurationError.unsupportedScheme("ftp")) {
            try LinuxProxyConfiguration(url: "ftp://proxy.example.com:21")
        }
        #expect(throws: LinuxProxyConfigurationError.missingHost) {
            try LinuxProxyConfiguration(url: "http:///missing-host")
        }
        #expect(throws: LinuxProxyConfigurationError.invalidPort) {
            try LinuxProxyConfiguration(url: "http://proxy.example.com:70000")
        }
        #expect(throws: LinuxProxyConfigurationError.unsupportedComponents) {
            try LinuxProxyConfiguration(url: "http://proxy.example.com/path?q=1")
        }
    }

    #if os(Linux)
    @Test("URLSession transport sends HTTP traffic through the configured proxy")
    func transportUsesConfiguredProxy() async throws {
        let capture = try OneShotProxyCapture()
        defer { capture.close() }
        let proxy = try LinuxProxyConfiguration(
            url: "http://127.0.0.1:\(capture.port)"
        )
        let keys = Array(proxy.processEnvironment.keys)
        let previous = Dictionary(uniqueKeysWithValues: keys.map {
            ($0, ProcessInfo.processInfo.environment[$0])
        })
        defer {
            for (key, value) in previous {
                if let value {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
        }
        proxy.applyToProcessEnvironment()
        let transport = URLSessionTransport()
        let captured = Task.detached { try capture.receiveRequest() }
        var request = URLRequest(
            url: URL(string: "http://unreachable.invalid/openusage-proxy-check")!
        )
        request.timeoutInterval = 5

        let result = try await transport.execute(request)
        let requestLine = try await captured.value

        #expect(result.statusCode == 200)
        #expect(result.data == Data("proxy-ok".utf8))
        #expect(requestLine == "GET http://unreachable.invalid/openusage-proxy-check HTTP/1.1")
    }
    #endif
}

#if os(Linux)
private final class OneShotProxyCapture: @unchecked Sendable {
    let descriptor: Int32
    let port: UInt16

    init() throws {
        let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        address.sin_port = 0
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Glibc.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(descriptor, 1) == 0 else {
            _ = Glibc.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else {
            _ = Glibc.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        self.descriptor = descriptor
        port = UInt16(bigEndian: bound.sin_port)
    }

    func close() {
        _ = Glibc.shutdown(descriptor, Int32(SHUT_RDWR))
        _ = Glibc.close(descriptor)
    }

    func receiveRequest() throws -> String {
        var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&event, 1, 5_000) > 0 else { throw POSIXError(.ETIMEDOUT) }
        let client = accept(descriptor, nil, nil)
        guard client >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = Glibc.close(client) }
        var bytes = [UInt8](repeating: 0, count: 8_192)
        let count = recv(client, &bytes, bytes.count, 0)
        guard count > 0 else { throw POSIXError(.ECONNRESET) }
        let request = String(decoding: bytes.prefix(count), as: UTF8.self)
        let response = Data(
            "HTTP/1.1 200 OK\r\nContent-Length: 8\r\nConnection: close\r\n\r\nproxy-ok".utf8
        )
        try response.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = send(
                    client,
                    buffer.baseAddress?.advanced(by: offset),
                    buffer.count - offset,
                    Int32(MSG_NOSIGNAL)
                )
                guard written > 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += written
            }
        }
        return request.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
    }
}
#endif
