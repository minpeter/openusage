import Foundation

public enum UsageExportFormat: Sendable {
    case csv
    case json
}

public enum UsageImportError: Error, Equatable {
    case fileTooLarge(maximumBytes: Int)
}

public struct UsageExportService: Sendable {
    public init() {}

    public func encode(
        _ snapshots: [ProviderUsageSnapshot],
        format: UsageExportFormat
    ) throws -> Data {
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(snapshots)
        case .csv:
            return Data(csv(snapshots).utf8)
        }
    }

    public func decodeJSON(_ data: Data) throws -> [ProviderUsageSnapshot] {
        guard data.count <= SnapshotCache.maximumBytes else {
            throw UsageImportError.fileTooLarge(maximumBytes: SnapshotCache.maximumBytes)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([ProviderUsageSnapshot].self, from: data)
    }

    private func csv(_ snapshots: [ProviderUsageSnapshot]) -> String {
        var output = [
            "provider,instance,account,plan,metric,kind,value,unit,limit,reset"
        ]
        for snapshot in snapshots {
            for metric in snapshot.metrics {
                output.append(contentsOf: rows(snapshot: snapshot, metric: metric))
            }
        }
        return output.joined(separator: "\n") + "\n"
    }

    private func rows(
        snapshot: ProviderUsageSnapshot,
        metric: UsageMetric
    ) -> [String] {
        if let values = metric.values, !values.isEmpty {
            return values.map {
                row(
                    snapshot: snapshot,
                    metric: "\(metric.label) / \($0.label)",
                    kind: metric.kind.rawValue,
                    value: $0.value,
                    unit: $0.unit.rawValue,
                    limit: nil,
                    reset: metric.resetsAt
                )
            }
        }
        if let points = metric.points, !points.isEmpty {
            return points.map {
                row(
                    snapshot: snapshot,
                    metric: metric.label,
                    kind: metric.kind.rawValue,
                    value: $0.value,
                    unit: "point",
                    limit: nil,
                    reset: $0.date
                )
            }
        }
        let value = metric.text ?? number(metric.used)
        return [
            row(
                snapshot: snapshot,
                metric: metric.label,
                kind: metric.kind.rawValue,
                value: value,
                unit: "",
                limit: metric.limit,
                reset: metric.resetsAt
            )
        ]
    }

    private func row(
        snapshot: ProviderUsageSnapshot,
        metric: String,
        kind: String,
        value: Double,
        unit: String,
        limit: Double?,
        reset: Date?
    ) -> String {
        row(
            snapshot: snapshot,
            metric: metric,
            kind: kind,
            value: number(value),
            unit: unit,
            limit: limit,
            reset: reset
        )
    }

    private func row(
        snapshot: ProviderUsageSnapshot,
        metric: String,
        kind: String,
        value: String,
        unit: String,
        limit: Double?,
        reset: Date?
    ) -> String {
        [
            snapshot.displayName,
            snapshot.instanceID,
            snapshot.accountLabel ?? "",
            snapshot.plan ?? "",
            metric,
            kind,
            value,
            unit,
            limit.map(number) ?? "",
            reset.map { Date.ISO8601FormatStyle().format($0) } ?? "",
        ].map(escape).joined(separator: ",")
    }

    private func number(_ value: Double) -> String {
        value.formatted(.number.grouping(.never).precision(.fractionLength(0...6)))
    }

    private func escape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
