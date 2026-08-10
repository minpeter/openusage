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
    static let requestHeadReadDeadlineMilliseconds: Int32 = 1_000

    private let requestedPort: Int
    private let source: any ProviderSnapshotSource
    private let queue = DispatchQueue(label: "openusage.linux.local-api")
    private let clientQueue = DispatchQueue(
        label: "openusage.linux.local-api.clients",
        attributes: .concurrent
    )
    private let lock = NSLock()
    private let workers = DispatchGroup()
    private var listener: Int32 = -1
    private var activeClients: Set<Int32> = []
    private var didStop = false
    public private(set) var port: Int

    public init(port: Int = defaultPort, source: any ProviderSnapshotSource) throws {
        guard (0...65_535).contains(port) else { throw LoopbackHTTPServerError.invalidPort(port) }
        requestedPort = port
        self.port = port
        self.source = source
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
        for client in activeClients {
            _ = shutdown(client, Int32(SHUT_RDWR))
        }
        lock.unlock()
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
            guard reserveConnection(client) else {
                send(Self.http(LinuxUsageAPI.busyResponse), to: client)
                _ = Glibc.close(client)
                continue
            }
            clientQueue.async {
                self.handle(client)
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
        let wasActive = activeClients.remove(client) != nil
        lock.unlock()
        if wasActive { workers.leave() }
    }

    private func handle(_ client: Int32) {
        guard let request = Self.readRequest(client) else { return }
        let completed = DispatchSemaphore(value: 0)
        Task {
            let snapshots = await source.snapshots(force: false)
            let known = await source.knownProviderIDs()
            let state = LinuxUsageAPIState(knownProviderIDs: known, snapshots: snapshots)
            let response = LinuxUsageAPI.respond(method: request.method, path: request.path, state: state)
            send(Self.http(response), to: client)
            completed.signal()
        }
        completed.wait()
    }

    private static func readRequest(_ descriptor: Int32) -> (method: String, path: String)? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(requestHeadReadDeadlineMilliseconds) * 1_000_000
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
                return parseRequestLine(head)
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

    private static func http(_ response: LinuxUsageAPIResponse) -> Data {
        let reason: String = switch response.status {
        case 200: "OK"
        case 204: "No Content"
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

    private func send(_ data: Data, to descriptor: Int32) {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let count = Glibc.send(descriptor, base.advanced(by: sent), data.count - sent, Int32(MSG_NOSIGNAL))
                if count <= 0 { return }
                sent += count
            }
        }
    }
}
#endif
