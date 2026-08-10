import Foundation
import Glibc

public protocol ProviderFileReading: Sendable {
    func readIfPresent(_ url: URL) throws -> Data?
}

public enum ProviderFileReadError: Error, LocalizedError, Equatable, Sendable {
    case unreadable(path: String)
    case tooLarge(path: String, maximumBytes: Int)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path):
            "Could not read \(path)."
        case .tooLarge(let path, let maximumBytes):
            "Refused to read \(path) because it exceeds \(maximumBytes) bytes."
        }
    }
}

/// Reads provider-owned auth files without allowing a corrupt or hostile file to be loaded unboundedly.
public struct BoundedProviderFileReader: ProviderFileReading {
    public static let defaultMaximumBytes = 512 * 1024
    public let maximumBytes: Int

    public init(maximumBytes: Int = BoundedProviderFileReader.defaultMaximumBytes) {
        precondition(maximumBytes >= 0)
        self.maximumBytes = maximumBytes
    }

    public func read(_ url: URL) throws -> Data {
        guard let data = try readIfPresent(url) else {
            throw ProviderFileReadError.unreadable(path: url.path)
        }
        return data
    }

    public func readIfPresent(_ url: URL) throws -> Data? {
        try readIfPresent(url, validating: { _ in true })
    }

    func readIfPresent(
        _ url: URL,
        validating descriptorMetadata: (stat) -> Bool
    ) throws -> Data? {
        let descriptor = url.path.withCString {
            Glibc.open($0, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw ProviderFileReadError.unreadable(path: url.path)
        }
        defer { _ = Glibc.close(descriptor) }

        var metadata = stat()
        guard Glibc.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              descriptorMetadata(metadata)
        else {
            throw ProviderFileReadError.unreadable(path: url.path)
        }
        if metadata.st_size > off_t(maximumBytes) {
            throw ProviderFileReadError.tooLarge(path: url.path, maximumBytes: maximumBytes)
        }

        let readLimit = maximumBytes + 1
        var data = Data()
        data.reserveCapacity(min(readLimit, 8 * 1024))
        var buffer = [UInt8](repeating: 0, count: min(readLimit, 8 * 1024))
        while data.count < readLimit {
            let requested = min(buffer.count, readLimit - data.count)
            let count = buffer.withUnsafeMutableBytes { bytes in
                Glibc.read(descriptor, bytes.baseAddress, requested)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw ProviderFileReadError.unreadable(path: url.path)
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count <= maximumBytes else {
            throw ProviderFileReadError.tooLarge(path: url.path, maximumBytes: maximumBytes)
        }
        return data
    }
}
