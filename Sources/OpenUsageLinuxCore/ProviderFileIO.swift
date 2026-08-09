import Foundation

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
        self.maximumBytes = maximumBytes
    }

    public func read(_ url: URL) throws -> Data {
        guard let data = try readIfPresent(url) else {
            throw ProviderFileReadError.unreadable(path: url.path)
        }
        return data
    }

    public func readIfPresent(_ url: URL) throws -> Data? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            if let size = attributes[.size] as? NSNumber, size.intValue > maximumBytes {
                throw ProviderFileReadError.tooLarge(path: url.path, maximumBytes: maximumBytes)
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
            guard data.count <= maximumBytes else {
                throw ProviderFileReadError.tooLarge(path: url.path, maximumBytes: maximumBytes)
            }
            return data
        } catch let error as ProviderFileReadError {
            throw error
        } catch {
            throw ProviderFileReadError.unreadable(path: url.path)
        }
    }
}
