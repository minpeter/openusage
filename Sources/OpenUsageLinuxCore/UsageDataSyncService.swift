import Foundation

public struct UsageDataSyncService: Sendable {
    private let cache: SnapshotCache
    private let now: @Sendable () -> Date

    public init(
        cache: SnapshotCache = SnapshotCache(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.cache = cache
        self.now = now
    }

    public func export(
        _ snapshots: [ProviderUsageSnapshot],
        format: UsageExportFormat,
        to directory: URL
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try UsageExportService().encode(snapshots, format: format)
        let fileExtension = format == .json ? "json" : "csv"
        let stem = "openusage-\(Int(now().timeIntervalSince1970))"
        var suffix = 1
        while true {
            let name = suffix == 1
                ? "\(stem).\(fileExtension)"
                : "\(stem)-\(suffix).\(fileExtension)"
            let destination = directory.appendingPathComponent(name)
            do {
                try data.write(to: destination, options: .withoutOverwriting)
                return destination
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                suffix += 1
            }
        }
    }

    @discardableResult
    public func importSnapshots(from file: URL) throws -> [ProviderUsageSnapshot] {
        let data = try BoundedProviderFileReader(
            maximumBytes: SnapshotCache.maximumBytes
        ).read(file)
        let snapshots = try UsageExportService().decodeJSON(data)
        try cache.save(snapshots)
        return snapshots
    }
}
