import Foundation

public struct OpenCodeLocalScan: Sendable {
    let rows: [OpenCodeLocalScanner.Row]
    let anchorMs: Double?
    let hasGoSignal: Bool
}

public struct OpenCodeLocalScanner: Sendable {
    public static let maximumQueryBytes = 512 * 1024
    private let sqlite: any OpenCodeSQLiteAccessing
    private let databasePaths: @Sendable () throws -> [URL]
    private let maximumQueryBytes: Int

    public init(
        sqlite: any OpenCodeSQLiteAccessing = OpenCodeSQLiteCLI(),
        databasePaths: @escaping @Sendable () throws -> [URL] = {
            try OpenCodeLinuxPaths().databaseFiles()
        },
        maximumQueryBytes: Int = OpenCodeLocalScanner.maximumQueryBytes
    ) {
        self.sqlite = sqlite; self.databasePaths = databasePaths; self.maximumQueryBytes = maximumQueryBytes
    }

    public func scan(now: Date, daysBack: Int = 33, hasGoKey: Bool = false) async throws -> OpenCodeLocalScan? {
        let paths: [URL]
        do { paths = try databasePaths() }
        catch { throw OpenCodeLinuxError.databaseUnreadable }
        guard !paths.isEmpty else { return nil }

        let cutoff = Int((now.timeIntervalSince1970 - Double(daysBack) * 86_400) * 1000)
        var rows: [Row] = []
        var anchor: Double?
        var failed = 0
        for path in paths {
            do {
                if let data = try sqlite.query(path: path, sql: Self.dataSQL(cutoffMs: cutoff), maximumBytes: maximumQueryBytes) {
                    rows += Self.parseRows(data)
                }
            } catch {
                failed += 1
                continue
            }
            let anchorData: Data?
            do { anchorData = try sqlite.query(path: path, sql: Self.anchorSQL, maximumBytes: 128) }
            catch { anchorData = nil }
            if let anchorData, let text = String(data: anchorData, encoding: .utf8),
               let number = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                anchor = min(anchor ?? number, number)
            }
        }
        guard failed < paths.count else { throw OpenCodeLinuxError.databaseUnreadable }
        let recentGo = rows.contains { $0.providerID == "opencode-go" }
        return OpenCodeLocalScan(rows: rows, anchorMs: anchor, hasGoSignal: hasGoKey || recentGo)
    }

    public func hasHostedUsage() async -> Bool {
        guard let paths = try? databasePaths() else { return true }
        for path in paths {
            do {
                if try sqlite.query(path: path, sql: Self.probeSQL, maximumBytes: 8) != nil { return true }
            } catch { continue }
        }
        return false
    }

    struct Row: Sendable {
        let ms: Double
        let cost: Double
        let tokens: Int
        let model: String
        let providerID: String
    }

    private static func parseRows(_ data: Data) -> [Row] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return root.compactMap { item in
            guard let values = item as? [Any], values.count >= 5,
                  let ms = number(values[0]), let cost = number(values[1]), cost >= 0,
                  let provider = values[4] as? String else { return nil }
            let tokenValue = min(max(number(values[2]) ?? 0, 0), 1e15)
            return Row(ms: ms, cost: cost, tokens: Int(tokenValue), model: values[3] as? String ?? "", providerID: provider)
        }
    }

    private static func number(_ value: Any) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    static func dataSQL(cutoffMs: Int) -> String {
        """
        SELECT json_group_array(json_array(time_created, json_extract(data,'$.cost'),
          COALESCE(json_extract(data,'$.tokens.total'),0), json_extract(data,'$.modelID'),
          json_extract(data,'$.providerID'))) FROM message
        WHERE time_created >= \(cutoffMs) AND json_valid(data)
          AND json_extract(data,'$.role') = 'assistant'
          AND json_extract(data,'$.providerID') IN ('opencode-go','opencode')
          AND json_type(data,'$.cost') IN ('integer','real');
        """
    }

    static let anchorSQL = """
        SELECT MIN(time_created) FROM message WHERE json_valid(data)
          AND json_extract(data,'$.role') = 'assistant'
          AND json_extract(data,'$.providerID') = 'opencode-go'
          AND json_type(data,'$.cost') IN ('integer','real');
        """
    static let probeSQL = """
        SELECT 1 FROM message WHERE json_valid(data) AND json_extract(data,'$.role') = 'assistant'
          AND json_extract(data,'$.providerID') IN ('opencode-go','opencode')
          AND json_type(data,'$.cost') IN ('integer','real') LIMIT 1;
        """
}
