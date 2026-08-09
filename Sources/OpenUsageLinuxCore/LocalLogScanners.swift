import Foundation

public enum LocalLogScanError: Error, Equatable {
    case lineTooLarge(maximumBytes: Int)
    case tooManyEvents(maximum: Int)
}

enum BoundedJSONL {
    static let maximumLineBytes = 512 * 1_024
    // Retained parsed records and their dedup indexes stay below the 10 MiB refresh-growth budget.
    // JSON lines themselves are streamed and never retained with these records.
    static let maximumEvents = 20_000
    static let chunkBytes = 64 * 1_024

    static func lines(at url: URL, consume: (Data) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var pending = Data(); pending.reserveCapacity(chunkBytes * 2)
        while true {
            let chunk = try handle.read(upToCount: chunkBytes) ?? Data()
            if chunk.isEmpty { break }
            pending.append(chunk)
            var start = pending.startIndex
            while let newline = pending[start...].firstIndex(of: UInt8(ascii: "\n")) {
                let length = pending.distance(from: start, to: newline)
                guard length <= maximumLineBytes else { throw LocalLogScanError.lineTooLarge(maximumBytes: maximumLineBytes) }
                if length > 0 { try consume(Data(pending[start..<newline])) }
                start = pending.index(after: newline)
            }
            if start > pending.startIndex { pending.removeSubrange(pending.startIndex..<start) }
            guard pending.count <= maximumLineBytes else { throw LocalLogScanError.lineTooLarge(maximumBytes: maximumLineBytes) }
        }
        if !pending.isEmpty { try consume(pending) }
    }

    static func jsonlFiles(under directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var files: [URL] = []
        for case let file as URL in enumerator where file.pathExtension.lowercased() == "jsonl" {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values?.isRegularFile == true && values?.isSymbolicLink != true { files.append(file) }
        }
        return files.sorted { $0.path < $1.path }
    }
}

func localLogISODate(_ raw: Any?) -> Date? {
    guard let text = raw as? String else { return nil }
    let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
}

func localLogSince(now: Date, daysBack: Int, calendar: Calendar) -> Date {
    calendar.date(byAdding: .day, value: -max(0, min(daysBack, LocalUsageHistory.previousDays)),
                  to: calendar.startOfDay(for: now)) ?? now
}
func localLogNumber(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
func localLogNonnegativeInt(_ value: Double) -> Int {
    guard value.isFinite, value > 0 else { return 0 }
    return Int(min(value, Double(Int.max)))
}
