import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ResponseLimitError: Error, Equatable {
    case exceeded(maximumBytes: Int)
}

public struct ResponseSizePolicy: Equatable, Sendable {
    public let maximumBytes: Int

    public init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    public func allows(expectedContentLength: Int64) -> Bool {
        expectedContentLength < 0 || expectedContentLength <= Int64(maximumBytes)
    }
}

public struct BoundedDataAccumulator: Sendable {
    public let maximumBytes: Int
    public private(set) var data = Data()

    public init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
        data.reserveCapacity(min(maximumBytes, 64 * 1024))
    }

    public mutating func append(_ chunk: Data) throws {
        guard chunk.count <= maximumBytes - data.count else {
            throw ResponseLimitError.exceeded(maximumBytes: maximumBytes)
        }
        data.append(chunk)
    }
}

public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let delegate: BoundedSessionDelegate
    private let session: URLSession

    public init(maximumResponseBytes: Int = 512 * 1024) {
        delegate = BoundedSessionDelegate(maximumResponseBytes: maximumResponseBytes)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 45
        session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func execute(_ request: URLRequest) async throws -> HTTPResult {
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.register(task: task, continuation: continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

private final class BoundedSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Pending: Sendable {
        var accumulator: BoundedDataAccumulator
        var headers: [String: String]
        let continuation: CheckedContinuation<HTTPResult, Error>
    }

    private let maximumResponseBytes: Int
    private let responsePolicy: ResponseSizePolicy
    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]

    init(maximumResponseBytes: Int) {
        self.maximumResponseBytes = maximumResponseBytes
        responsePolicy = ResponseSizePolicy(maximumBytes: maximumResponseBytes)
    }

    func register(
        task: URLSessionDataTask,
        continuation: CheckedContinuation<HTTPResult, Error>
    ) {
        lock.withLock {
            pending[task.taskIdentifier] = Pending(
                accumulator: BoundedDataAccumulator(maximumBytes: maximumResponseBytes),
                headers: [:],
                continuation: continuation
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        if !responsePolicy.allows(expectedContentLength: response.expectedContentLength) {
            fail(taskID: dataTask.taskIdentifier)
            completionHandler(.cancel)
            return
        }
        if let response = response as? HTTPURLResponse {
            lock.withLock {
                guard var value = pending[dataTask.taskIdentifier] else { return }
                value.headers = response.allHeaderFields.reduce(into: [:]) { headers, entry in
                    headers[String(describing: entry.key)] = String(describing: entry.value)
                }
                pending[dataTask.taskIdentifier] = value
            }
        }
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        let failure = lock.withLock { () -> CheckedContinuation<HTTPResult, Error>? in
            guard var value = pending[dataTask.taskIdentifier] else { return nil }
            do {
                try value.accumulator.append(data)
                pending[dataTask.taskIdentifier] = value
                return nil
            } catch {
                pending[dataTask.taskIdentifier] = nil
                return value.continuation
            }
        }
        if let failure {
            failure.resume(throwing: ResponseLimitError.exceeded(maximumBytes: maximumResponseBytes))
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let value = lock.withLock { pending.removeValue(forKey: task.taskIdentifier) }
        guard let value else { return }
        if let error {
            value.continuation.resume(throwing: error)
            return
        }
        guard let response = task.response as? HTTPURLResponse else {
            value.continuation.resume(throwing: LinuxUsageError.invalidResponse("HTTP"))
            return
        }
        value.continuation.resume(
            returning: HTTPResult(
                data: value.accumulator.data,
                statusCode: response.statusCode,
                headers: value.headers
            )
        )
    }

    private func fail(taskID: Int) {
        let value = lock.withLock { pending.removeValue(forKey: taskID) }
        value?.continuation.resume(
            throwing: ResponseLimitError.exceeded(maximumBytes: maximumResponseBytes)
        )
    }
}
