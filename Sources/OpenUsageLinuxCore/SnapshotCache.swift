import Foundation

public enum SnapshotCacheError: Error, Equatable {
    case fileTooLarge(maximumBytes: Int)
    case tooManyMetrics(maximum: Int)
    case tooManyProviders(maximum: Int)
}

public struct SnapshotCache: Sendable {
    public static let maximumBytes = 1_048_576
    public static let maximumProviders = 32
    public static let maximumMetricsPerProvider = 64

    public let paths: LinuxPaths

    public init(paths: LinuxPaths = LinuxPaths()) {
        self.paths = paths
    }

    public func load() throws -> [ProviderUsageSnapshot] {
        guard FileManager.default.fileExists(atPath: paths.snapshotCache.path) else {
            return []
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: paths.snapshotCache.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size <= Self.maximumBytes else {
            throw SnapshotCacheError.fileTooLarge(maximumBytes: Self.maximumBytes)
        }
        let data = try Data(contentsOf: paths.snapshotCache)
        let snapshots = try decoder.decode([ProviderUsageSnapshot].self, from: data)
        try validate(snapshots)
        return snapshots
    }

    public func save(_ snapshots: [ProviderUsageSnapshot]) throws {
        try validate(snapshots)
        try paths.prepareStorage()
        let data = try encoder.encode(snapshots)
        guard data.count <= Self.maximumBytes else {
            throw SnapshotCacheError.fileTooLarge(maximumBytes: Self.maximumBytes)
        }
        try data.write(to: paths.snapshotCache, options: .atomic)
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func validate(_ snapshots: [ProviderUsageSnapshot]) throws {
        guard snapshots.count <= Self.maximumProviders else {
            throw SnapshotCacheError.tooManyProviders(maximum: Self.maximumProviders)
        }
        guard snapshots.allSatisfy({ $0.metrics.count <= Self.maximumMetricsPerProvider }) else {
            throw SnapshotCacheError.tooManyMetrics(maximum: Self.maximumMetricsPerProvider)
        }
    }
}
