#if os(Linux)
import Dispatch
import Foundation
import Glibc

public enum LoopbackHTTPServerError: Error, LocalizedError, Equatable {
    case invalidPort(Int)
    case socketFailure(Int32)
    case bindFailure(Int32)
    case listenFailure(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidPort(let port): "Invalid port: \(port)."
        case .socketFailure(let code): "Could not create loopback socket (errno \(code))."
        case .bindFailure(let code): "Could not bind loopback port (errno \(code))."
        case .listenFailure(let code): "Could not listen on loopback port (errno \(code))."
        }
    }
}

/// Small HTTP/1.1 loopback transport. It binds only 127.0.0.1, bounds request heads/concurrency,
/// emits close-delimited responses, and makes shutdown idempotent.
public final class LoopbackHTTPServer: @unchecked Sendable {
    public static let defaultPort = 6736
    public static let maximumRequestHeadBytes = 8_192
    public static let maximumConcurrentConnections = 16
    static let defaultClientLifetimeMilliseconds: Int32 = 15_000

    private let requestedPort: Int
    private let source: any ProviderSnapshotSource
    private let clientLifetimeMilliseconds: Int32
    private let queue = DispatchQueue(label: "openusage.linux.local-api")
    private let clientQueue = DispatchQueue(
        label: "openusage.linux.local-api.clients",
        attributes: .concurrent
    )
    private let lock = NSLock()
    private let workers = DispatchGroup()
    private var listener: Int32 = -1
    private var activeClients: Set<Int32> = []
    private var activeResponseWork: [Int32: ResponseWork] = [:]
    private var didStop = false
    public private(set) var port: Int

    public convenience init(port: Int = defaultPort, source: any ProviderSnapshotSource) throws {
        try self.init(
            port: port,
            source: source,
            clientLifetimeMilliseconds: Self.defaultClientLifetimeMilliseconds
        )
    }

    init(
        port: Int,
        source: any ProviderSnapshotSource,
        clientLifetimeMilliseconds: Int32
    ) throws {
        guard (0...65_535).contains(port) else { throw LoopbackHTTPServerError.invalidPort(port) }
        guard clientLifetimeMilliseconds > 0 else {
            throw LoopbackHTTPServerError.socketFailure(EINVAL)
        }
        requestedPort = port
        self.port = port
        self.source = source
        self.clientLifetimeMilliseconds = clientLifetimeMilliseconds
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard listener < 0, !didStop else { return }

        let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard descriptor >= 0 else { throw LoopbackHTTPServerError.socketFailure(errno) }
        var reuse: Int32 = 1
        _ = withUnsafePointer(to: &reuse) {
            setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, $0, socklen_t(MemoryLayout<Int32>.size))
        }
        var address = sockaddr_in(
            sin_family: sa_family_t(AF_INET),
            sin_port: in_port_t(requestedPort).bigEndian,
            sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")),
            sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
        )
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Glibc.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let code = errno
            _ = Glibc.close(descriptor)
            throw LoopbackHTTPServerError.bindFailure(code)
        }
        guard Glibc.listen(descriptor, Int32(Self.maximumConcurrentConnections)) == 0 else {
            let code = errno
            _ = Glibc.close(descriptor)
            throw LoopbackHTTPServerError.listenFailure(code)
        }
        if requestedPort == 0 {
            var bound = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            withUnsafeMutablePointer(to: &bound) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = getsockname(descriptor, $0, &length)
                }
            }
            port = Int(in_port_t(bigEndian: bound.sin_port))
        }
        listener = descriptor
        workers.enter()
        queue.async { self.acceptLoop(descriptor) }
    }

    public func stop() {
        lock.lock()
        guard !didStop else {
            lock.unlock()
            return
        }
        didStop = true
        let descriptor = listener
        listener = -1
        let responseWork = Array(activeResponseWork.values)
        for client in activeClients {
            _ = shutdown(client, Int32(SHUT_RDWR))
        }
        lock.unlock()
        responseWork.forEach { $0.cancel() }
        if descriptor >= 0 {
            _ = shutdown(descriptor, Int32(SHUT_RDWR))
            _ = Glibc.close(descriptor)
        }
    }

    public func waitUntilStopped() {
        workers.wait()
    }

    deinit { stop() }

    private func acceptLoop(_ descriptor: Int32) {
        defer { workers.leave() }
        while true {
            let client = Glibc.accept(descriptor, nil, nil)
            if client < 0 {
                lock.lock()
                let stopping = didStop
                lock.unlock()
                if stopping { return }
                continue
            }
            let deadline = Self.deadline(after: clientLifetimeMilliseconds)
            guard reserveConnection(client) else {
                Self.sendWithDeadline(Self.http(LinuxUsageAPI.busyResponse), to: client, deadline: deadline)
                _ = Glibc.close(client)
                continue
            }
            clientQueue.async {
                self.handle(client, deadline: deadline)
                self.finishConnection(client)
            }
        }
    }

    private func reserveConnection(_ client: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didStop, activeClients.count < Self.maximumConcurrentConnections else { return false }
        activeClients.insert(client)
        workers.enter()
        return true
    }

    private func finishConnection(_ client: Int32) {
        lock.lock()
        _ = Glibc.close(client)
        activeResponseWork.removeValue(forKey: client)
        let wasActive = activeClients.remove(client) != nil
        lock.unlock()
        if wasActive { workers.leave() }
    }

    private func handle(_ client: Int32, deadline: UInt64) {
        guard let request = Self.readRequest(client, deadline: deadline) else { return }
        guard Self.isLoopbackAuthority(request.host) else {
            Self.sendWithDeadline(Self.http(Self.forbidden("invalid_host")), to: client, deadline: deadline)
            return
        }
        guard request.origin.map(Self.isLoopbackOrigin) != false else {
            Self.sendWithDeadline(Self.http(Self.forbidden("forbidden_origin")), to: client, deadline: deadline)
            return
        }

        let work = ResponseWork()
        lock.lock()
        guard !didStop else {
            lock.unlock()
            return
        }
        activeResponseWork[client] = work
        lock.unlock()
        let source = self.source
        work.start {
            let snapshots = await source.snapshots(force: false)
            let known = await source.knownProviderIDs()
            let state = LinuxUsageAPIState(knownProviderIDs: known, snapshots: snapshots)
            return LinuxUsageAPI.respond(method: request.method, path: request.path, state: state)
        }
        guard work.wait(until: deadline), let response = work.response else {
            work.cancel()
            return
        }
        Self.sendWithDeadline(Self.http(response), to: client, deadline: deadline)
    }

    private static func readRequest(_ descriptor: Int32, deadline: UInt64) -> HTTPRequest? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while data.count < maximumRequestHeadBytes {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return nil }
            let remaining = deadline - now
            let timeout = Int32(min((remaining + 999_999) / 1_000_000, UInt64(Int32.max)))
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            let ready = Glibc.poll(&pollDescriptor, 1, timeout)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { return nil }

            let count = Glibc.recv(descriptor, &buffer, min(buffer.count, maximumRequestHeadBytes - data.count), 0)
            guard count > 0 else { return nil }
            data.append(buffer, count: count)
            if let range = data.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(data: data[..<range.lowerBound], encoding: .utf8) ?? ""
                return parseRequest(head)
            }
        }
        return nil
    }

    public static func parseRequestLine(_ head: String) -> (method: String, path: String) {
        guard let line = head.split(separator: "\r\n", maxSplits: 1).first else { return ("", "/") }
        let parts = line.split(separator: " ")
        return (
            parts.indices.contains(0) ? String(parts[0]) : "",
            parts.indices.contains(1) ? String(parts[1]) : "/"
        )
    }

    private static func parseRequest(_ head: String) -> HTTPRequest? {
        let lines = head.components(separatedBy: "\r\n")
        guard let line = lines.first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count == 3 else { return nil }
        var headers: [String: [String]] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { return nil }
            let name = line[..<separator].lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            headers[name, default: []].append(value)
        }
        guard headers["host"]?.count == 1, (headers["origin"]?.count ?? 0) <= 1 else { return nil }
        return HTTPRequest(
            method: String(parts[0]),
            path: String(parts[1]),
            host: headers["host"]![0],
            origin: headers["origin"]?.first
        )
    }

    private static func isLoopbackAuthority(_ authority: String) -> Bool {
        let value = authority.lowercased()
        if value.hasPrefix("[") {
            guard let closing = value.firstIndex(of: "]") else { return false }
            let host = String(value[value.index(after: value.startIndex)..<closing])
            return host == "::1" && validPortSuffix(String(value[value.index(after: closing)...]))
        }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2, parts.first == "127.0.0.1" || parts.first == "localhost" else { return false }
        return parts.count == 1 || validPort(String(parts[1]))
    }

    private static func isLoopbackOrigin(_ origin: String) -> Bool {
        guard let components = URLComponents(string: origin),
              components.scheme == "http" || components.scheme == "https",
              let host = components.host?.lowercased(),
              host == "127.0.0.1" || host == "localhost" || host == "::1",
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty
        else { return false }
        return true
    }

    private static func validPortSuffix(_ suffix: String) -> Bool {
        suffix.isEmpty || (suffix.first == ":" && validPort(String(suffix.dropFirst())))
    }

    private static func validPort(_ port: String) -> Bool {
        guard !port.isEmpty, port.allSatisfy(\.isNumber), let value = Int(port) else { return false }
        return (0...65_535).contains(value)
    }

    private static func forbidden(_ code: String) -> LinuxUsageAPIResponse {
        LinuxUsageAPIResponse(status: 403, body: Data(#"{"error":"\#(code)"}"#.utf8))
    }

    private static func http(_ response: LinuxUsageAPIResponse) -> Data {
        let reason: String = switch response.status {
        case 200: "OK"
        case 204: "No Content"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 503: "Service Unavailable"
        default: "OK"
        }
        let body = response.body ?? Data()
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        head += "Connection: close\r\n"
        if response.body != nil { head += "Content-Type: application/json\r\n" }
        head += "Content-Length: \(body.count)\r\n\r\n"
        return Data(head.utf8) + body
    }

    static func sendWithDeadline(_ data: Data, to descriptor: Int32, deadline: UInt64) {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { return }
                let remaining = deadline - now
                let timeout = Int32(min((remaining + 999_999) / 1_000_000, UInt64(Int32.max)))
                var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT | POLLHUP), revents: 0)
                let ready = Glibc.poll(&pollDescriptor, 1, timeout)
                if ready < 0, errno == EINTR { continue }
                guard ready > 0, pollDescriptor.revents & Int16(POLLOUT) != 0 else { return }
                let count = Glibc.send(
                    descriptor,
                    base.advanced(by: sent),
                    data.count - sent,
                    Int32(MSG_NOSIGNAL | MSG_DONTWAIT)
                )
                if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                guard count > 0 else { return }
                sent += count
            }
        }
    }

    private static func deadline(after milliseconds: Int32) -> UInt64 {
        DispatchTime.now().uptimeNanoseconds + UInt64(milliseconds) * 1_000_000
    }
}

private struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let host: String
    let origin: String?
}

private final class ResponseWork: @unchecked Sendable {
    private let lock = NSLock()
    private let completed = DispatchSemaphore(value: 0)
    private var task: Task<Void, Never>?
    private var isCancelled = false
    private var storedResponse: LinuxUsageAPIResponse?

    var response: LinuxUsageAPIResponse? {
        lock.withLock { isCancelled ? nil : storedResponse }
    }

    func start(_ operation: @escaping @Sendable () async -> LinuxUsageAPIResponse) {
        let task = Task {
            let response = await operation()
            lock.withLock { storedResponse = response }
            completed.signal()
        }
        lock.withLock {
            self.task = task
            if isCancelled { task.cancel() }
        }
    }

    func wait(until deadline: UInt64) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { return false }
        return completed.wait(timeout: .now() + .nanoseconds(Int(deadline - now))) == .success
    }

    func cancel() {
        lock.withLock {
            guard !isCancelled else { return }
            isCancelled = true
            task?.cancel()
            completed.signal()
        }
    }
}
#endif
