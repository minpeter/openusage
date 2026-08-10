import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(Linux)
import Glibc
#endif
import Testing
@testable import OpenUsageLinuxCore

@Suite("Linux usage API contract")
struct LinuxUsageAPIContractTests {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Usage preserves identity, provider metadata, and every metric shape")
    func usagePreservesCompleteSnapshot() throws {
        let snapshot = ProviderUsageSnapshot(
            providerID: "future-provider",
            instanceID: "future-provider@team",
            displayName: "Future Provider Team",
            accountLabel: "team@example.com",
            plan: "Enterprise",
            metrics: [
                UsageMetric(kind: .progress, label: "Session", used: 25, limit: 100, resetsAt: date, periodDurationMilliseconds: 18_000_000),
                UsageMetric(kind: .values, label: "Today", used: 0, values: [UsageValue(label: "Cost", value: 2.5, unit: .dollars)]),
                UsageMetric(kind: .badge, label: "Status", used: 0, text: "Ready"),
                UsageMetric(kind: .chart, label: "History", used: 0, points: [UsagePoint(date: date, value: 4.2)]),
                UsageMetric(kind: .text, label: "Notice", used: 0, text: "OK"),
            ],
            links: [ProviderLink(label: "Console", url: "https://example.com/console")],
            widgets: [WidgetDescriptor(id: "future-provider@team.session", title: "Session", metricLabel: "Session")],
            refreshedAt: date,
            warning: "cached"
        )
        let state = LinuxUsageAPIState(knownProviderIDs: ["future-provider"], snapshots: [snapshot], generatedAt: date)

        let response = LinuxUsageAPI.respond(method: "GET", path: "/v1/usage/future-provider", state: state)
        #expect(response.status == 200)
        let body = try #require(response.body)
        let array = try #require(JSONSerialization.jsonObject(with: body) as? [[String: Any]])
        let json = try #require(array.first)
        #expect(json["providerId"] as? String == "future-provider")
        #expect(json["instanceId"] as? String == "future-provider@team")
        #expect(json["accountLabel"] as? String == "team@example.com")
        #expect((json["links"] as? [[String: Any]])?.first?["url"] as? String == "https://example.com/console")
        #expect((json["widgets"] as? [[String: Any]])?.first?["id"] as? String == "future-provider@team.session")
        let lines = try #require(json["lines"] as? [[String: Any]])
        #expect(lines.compactMap { $0["type"] as? String } == ["progress", "text", "badge", "barChart", "text"])
        #expect(lines.compactMap { $0["kind"] as? String } == ["progress", "values", "badge", "chart", "text"])
        #expect((lines.first?["format"] as? [String: Any])?["kind"] as? String == "percent")
        #expect((lines[1]["values"] as? [[String: Any]])?.first?["unit"] as? String == "dollars")
    }

    @Test("Selection supports provider families and exact instance IDs without a hardcoded catalog")
    func genericSelection() throws {
        let snapshots = [
            ProviderUsageSnapshot(providerID: "new-adapter", instanceID: "new-adapter@one", displayName: "One", plan: nil, metrics: []),
            ProviderUsageSnapshot(providerID: "new-adapter", instanceID: "new-adapter@two", displayName: "Two", plan: nil, metrics: []),
        ]
        let state = LinuxUsageAPIState(knownProviderIDs: ["new-adapter"], snapshots: snapshots)

        let family = LinuxUsageAPI.respond(method: "GET", path: "/v1/usage/new-adapter", state: state)
        let exact = LinuxUsageAPI.respond(method: "GET", path: "/v1/usage/new-adapter@two", state: state)
        let unknown = LinuxUsageAPI.respond(method: "GET", path: "/v1/usage/nope", state: state)

        let familyBody = try #require(family.body)
        #expect((try JSONSerialization.jsonObject(with: familyBody) as? [Any])?.count == 2)
        let exactBody = try #require(exact.body)
        let exactJSON = try #require(JSONSerialization.jsonObject(with: exactBody) as? [[String: Any]])
        #expect(exactJSON.map { $0["instanceId"] as? String } == ["new-adapter@two"])
        #expect(unknown.status == 404)
        #expect(String(data: try #require(unknown.body), encoding: .utf8) == #"{"error":"provider_not_found"}"#)
    }

    @Test("Limits envelope is stable and keyed by account instance")
    func limitsEnvelope() throws {
        let snapshot = ProviderUsageSnapshot(
            providerID: "new-adapter", instanceID: "new-adapter@one", displayName: "New Adapter",
            accountLabel: "one", plan: "Pro",
            metrics: [UsageMetric(kind: .progress, label: "Weekly", used: 30, limit: 100, resetsAt: date)],
            widgets: [WidgetDescriptor(id: "new-adapter@one.weekly", title: "Weekly", metricLabel: "Weekly")],
            refreshedAt: date
        )
        let response = LinuxUsageAPI.respond(method: "GET", path: "/v1/limits", state: LinuxUsageAPIState(knownProviderIDs: ["new-adapter"], snapshots: [snapshot], generatedAt: date))
        let body = try #require(response.body)
        let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let providers = try #require(root["providers"] as? [String: Any])
        #expect(root["schema"] as? String == "openusage.limits.v1")
        #expect(providers["new-adapter@one"] != nil)
    }

    @Test("Port is configurable by environment and command line")
    func configurablePort() throws {
        #expect(try LinuxAPIArguments.parse([], environment: ["OPENUSAGE_PORT": "7000"]).port == 7000)
        #expect(try LinuxAPIArguments.parse(["--port", "7001"], environment: ["OPENUSAGE_PORT": "7000"]).port == 7001)
        #expect(try LinuxAPIArguments.parse(["--port", "0"], environment: [:]).port == 0)
        #expect(throws: LinuxCLIError.self) {
            try LinuxAPIArguments.parse(["--port", "70000"], environment: [:])
        }
    }

    @Test("Real API binary shuts down cleanly on SIGINT and SIGTERM after serving a request")
    func realBinarySignalShutdown() async throws {
        try await exerciseRealBinary(signal: SIGINT)
        try await exerciseRealBinary(signal: SIGTERM)
    }

    @Test("Loopback server serves JSON and shuts down idempotently")
    func loopbackLifecycle() async throws {
        let server = try LoopbackHTTPServer(port: 0, source: APIFixtureSource())
        try server.start()
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/v1/usage")!)
        request.timeoutInterval = 2
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect((try JSONSerialization.jsonObject(with: data) as? [Any])?.count == 1)
        server.stop()
        server.stop()
        server.waitUntilStopped()
    }

    @Test("Non-loopback authorities and foreign browser origins are rejected")
    func rejectsUntrustedAuthorities() throws {
        let server = try LoopbackHTTPServer(port: 0, source: APIFixtureSource())
        try server.start()
        defer {
            server.stop()
            server.waitUntilStopped()
        }

        let rebound = try LoopbackClient(port: server.port)
        try rebound.send("GET /v1/usage HTTP/1.1\r\nHost: attacker.example\r\n\r\n")
        #expect(try rebound.readToEnd(timeoutMilliseconds: 5_000).contains("HTTP/1.1 403 Forbidden"))

        let crossOrigin = try LoopbackClient(port: server.port)
        try crossOrigin.send("GET /v1/usage HTTP/1.1\r\nHost: localhost:\(server.port)\r\nOrigin: https://attacker.example\r\n\r\n")
        let response = try crossOrigin.readToEnd(timeoutMilliseconds: 5_000)
        #expect(response.contains("HTTP/1.1 403 Forbidden"))
        #expect(!response.lowercased().contains("access-control-allow-origin:"))

        let local = try LoopbackClient(port: server.port)
        try local.send("GET /v1/usage HTTP/1.1\r\nHost: 127.0.0.1:\(server.port)\r\nOrigin: http://localhost:\(server.port)\r\n\r\n")
        #expect(try local.readToEnd(timeoutMilliseconds: 5_000).contains("HTTP/1.1 200 OK"))
    }

    @Test("Stopping cancels stalled snapshot work and drains its worker")
    func stopCancelsStalledSnapshotWork() throws {
        let source = StalledSnapshotSource()
        let server = try LoopbackHTTPServer(port: 0, source: source)
        try server.start()
        let client = try LoopbackClient(port: server.port)
        try client.send("GET /v1/usage HTTP/1.1\r\nHost: 127.0.0.1:\(server.port)\r\n\r\n")
        #expect(source.started.wait(timeout: .now() + 1) == .success)

        server.stop()
        #expect(source.cancelled.wait(timeout: .now() + 1) == .success)
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            server.waitUntilStopped()
            drained.signal()
        }
        #expect(drained.wait(timeout: .now() + 1) == .success)
    }

    @Test("Socket writes stop at their absolute deadline")
    func socketWritesAreBounded() throws {
        var descriptors: [Int32] = [-1, -1]
        #expect(Glibc.socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &descriptors) == 0)
        defer {
            _ = Glibc.close(descriptors[0])
            _ = Glibc.close(descriptors[1])
        }
        var sendBuffer: Int32 = 1_024
        #expect(setsockopt(descriptors[0], SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout<Int32>.size)) == 0)
        let completed = DispatchSemaphore(value: 0)
        let sender = descriptors[0]
        DispatchQueue.global().async {
            LoopbackHTTPServer.sendWithDeadline(
                Data(repeating: 0x61, count: 1_000_000),
                to: sender,
                deadline: DispatchTime.now().uptimeNanoseconds + 100_000_000
            )
            completed.signal()
        }
        #expect(completed.wait(timeout: .now() + 1) == .success)
    }

    @Test("Idle clients expire and release every connection slot")
    func idleClientsReleaseConnectionSlots() throws {
        let server = try LoopbackHTTPServer(
            port: 0,
            source: APIFixtureSource(),
            clientLifetimeMilliseconds: 250
        )
        try server.start()
        defer {
            server.stop()
            server.waitUntilStopped()
        }

        let idleClients = try occupyEveryConnectionSlot(on: server)
        try expectServerBusy(on: server)
        try waitForPeerClosure(
            idleClients,
            timeoutMilliseconds: 2_000
        )

        let replacement = try LoopbackClient(port: server.port)
        try replacement.send("GET /v1/usage HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        #expect(try replacement.readToEnd(timeoutMilliseconds: 1_000).contains("HTTP/1.1 200 OK"))
    }

    @Test("Stopping closes accepted idle clients and waits for their tasks")
    func stopClosesAcceptedIdleClients() throws {
        let server = try LoopbackHTTPServer(port: 0, source: APIFixtureSource())
        try server.start()

        let idleClients = try occupyEveryConnectionSlot(on: server)
        try expectServerBusy(on: server)
        server.stop()
        try waitForPeerClosure(idleClients, timeoutMilliseconds: 1_000)
        server.waitUntilStopped()
    }

    private func occupyEveryConnectionSlot(on server: LoopbackHTTPServer) throws -> [LoopbackClient] {
        try (0..<LoopbackHTTPServer.maximumConcurrentConnections).map { _ in
            let client = try LoopbackClient(port: server.port)
            try client.send("GET /v1/usage HTTP/1.1\r\n")
            return client
        }
    }

    private func expectServerBusy(on server: LoopbackHTTPServer) throws {
        let overflow = try LoopbackClient(port: server.port)
        #expect(try overflow.readToEnd(timeoutMilliseconds: 1_000).contains("HTTP/1.1 503 Service Unavailable"))
    }

    private func exerciseRealBinary(signal: Int32) async throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("openusage-api")
        #expect(FileManager.default.isExecutableFile(atPath: executable.path))

        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--port", "0"]
        process.environment = [
            "HOME": home.path,
            "XDG_CONFIG_HOME": home.appendingPathComponent("config").path,
            "XDG_CACHE_HOME": home.appendingPathComponent("cache").path,
            "XDG_DATA_HOME": home.appendingPathComponent("data").path,
            "PATH": "/usr/bin:/bin",
        ]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()

        let readiness = errors.fileHandleForReading.availableData
        let readyText = String(decoding: readiness, as: UTF8.self)
        let portText = readyText.split(separator: ":").last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let port = try #require(portText.flatMap(Int.init))
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/limits")!)
        request.timeoutInterval = 5
        let (body, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(root["schema"] as? String == "openusage.limits.v1")

        #expect(Glibc.kill(process.processIdentifier, signal) == 0)
        process.waitUntilExit()
        let remainingErrors = errors.fileHandleForReading.readDataToEndOfFile()
        let errorText = readyText + String(decoding: remainingErrors, as: UTF8.self)
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 0)
        #expect(!errorText.contains("Signal 4"))
        #expect(!errorText.contains("Illegal instruction"))
        #expect(!errorText.contains("Swift runtime failure"))
    }

    @Test("Router rejects oversized serialized responses")
    func boundedResponse() {
        let huge = String(repeating: "x", count: LinuxUsageAPI.maximumResponseBytes + 1)
        let snapshot = ProviderUsageSnapshot(providerID: "large", displayName: huge, plan: nil, metrics: [])
        let response = LinuxUsageAPI.respond(method: "GET", path: "/v1/usage", state: LinuxUsageAPIState(knownProviderIDs: ["large"], snapshots: [snapshot]))
        #expect(response.status == 503)
        #expect(response.body.map { $0.count < 100 } == true)
    }
}

#if os(Linux)
private final class LoopbackClient {
    let descriptor: Int32

    init(port: Int) throws {
        descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard descriptor >= 0 else { throw SocketTestError.operation("socket", errno) }
        var address = sockaddr_in(
            sin_family: sa_family_t(AF_INET),
            sin_port: in_port_t(port).bigEndian,
            sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")),
            sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
        )
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Glibc.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            _ = Glibc.close(descriptor)
            throw SocketTestError.operation("connect", code)
        }
    }

    deinit { _ = Glibc.close(descriptor) }

    func send(_ request: String) throws {
        let data = Data(request.utf8)
        let result = data.withUnsafeBytes { bytes in
            Glibc.send(descriptor, bytes.baseAddress, data.count, Int32(MSG_NOSIGNAL))
        }
        guard result == data.count else { throw SocketTestError.operation("send", errno) }
    }

    func readToEnd(timeoutMilliseconds: Int32) throws -> String {
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while true {
            try waitForSocketEvent(descriptor, timeoutMilliseconds: timeoutMilliseconds)
            let count = Glibc.recv(descriptor, &buffer, buffer.count, 0)
            if count == 0 { return String(decoding: bytes, as: UTF8.self) }
            guard count > 0 else { throw SocketTestError.operation("recv", errno) }
            bytes.append(buffer, count: count)
        }
    }
}

private enum SocketTestError: Error {
    case operation(String, Int32)
    case timeout
    case peerDidNotClose
}

private func waitForSocketEvent(_ descriptor: Int32, timeoutMilliseconds: Int32) throws {
    var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
    let result = Glibc.poll(&pollDescriptor, 1, timeoutMilliseconds)
    guard result > 0 else {
        if result == 0 { throw SocketTestError.timeout }
        throw SocketTestError.operation("poll", errno)
    }
}

private func waitForPeerClosure(_ clients: [LoopbackClient], timeoutMilliseconds: Int32) throws {
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMilliseconds) * 1_000_000
    var openDescriptors = Set(clients.map(\.descriptor))
    while !openDescriptors.isEmpty {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { throw SocketTestError.timeout }
        let remaining = deadline - now
        let timeout = Int32(min((remaining + 999_999) / 1_000_000, UInt64(Int32.max)))
        var descriptors = openDescriptors.map {
            pollfd(fd: $0, events: Int16(POLLIN | POLLHUP), revents: 0)
        }
        let ready = Glibc.poll(&descriptors, nfds_t(descriptors.count), timeout)
        if ready < 0, errno == EINTR { continue }
        guard ready > 0 else {
            if ready == 0 { throw SocketTestError.timeout }
            throw SocketTestError.operation("poll", errno)
        }
        for descriptor in descriptors where descriptor.revents != 0 {
            var byte: UInt8 = 0
            let count = Glibc.recv(descriptor.fd, &byte, 1, Int32(MSG_DONTWAIT))
            if count == 0 {
                openDescriptors.remove(descriptor.fd)
            } else if count > 0 {
                throw SocketTestError.peerDidNotClose
            } else if errno == ECONNRESET {
                openDescriptors.remove(descriptor.fd)
            } else if errno != EAGAIN && errno != EWOULDBLOCK {
                throw SocketTestError.operation("recv", errno)
            }
        }
    }
}
#endif

private final class StalledSnapshotSource: ProviderSnapshotSource, @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let cancelled = DispatchSemaphore(value: 0)
    private let gate = CancellationGate()

    func knownProviderIDs() async -> Set<String> { [] }

    func snapshots(force: Bool) async -> [ProviderUsageSnapshot] {
        started.signal()
        await withTaskCancellationHandler {
            await gate.wait()
        } onCancel: {
            cancelled.signal()
            gate.cancel()
        }
        return []
    }
}

private final class CancellationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isCancelled = false

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                if isCancelled { return true }
                self.continuation = continuation
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }

    func cancel() {
        let continuation = lock.withLock {
            isCancelled = true
            return self.continuation
        }
        continuation?.resume()
    }
}

private actor APIFixtureSource: ProviderSnapshotSource {
    func knownProviderIDs() -> Set<String> { ["fixture"] }
    func snapshots(force: Bool) -> [ProviderUsageSnapshot] {
        [ProviderUsageSnapshot(providerID: "fixture", displayName: "Fixture", plan: nil, metrics: [])]
    }
}
