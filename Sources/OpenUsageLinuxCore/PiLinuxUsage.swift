import Foundation

public struct LinuxTokenBreakdown: Equatable, Sendable {
    public var input: Int
    public var cacheWrite5m: Int
    public var cacheWrite1h: Int
    public var cacheRead: Int
    public var output: Int

    public init(input: Int = 0, cacheWrite5m: Int = 0, cacheWrite1h: Int = 0, cacheRead: Int = 0, output: Int = 0) {
        self.input = input
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
        self.output = output
    }
}

public struct LinuxModelRates: Equatable, Sendable {
    public let inputPerMillion: Double
    public let outputPerMillion: Double
    public let cacheWritePerMillion: Double
    public let cacheReadPerMillion: Double

    public init(
        inputPerMillion: Double,
        outputPerMillion: Double,
        cacheWritePerMillion: Double? = nil,
        cacheReadPerMillion: Double? = nil
    ) {
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
        self.cacheWritePerMillion = cacheWritePerMillion ?? inputPerMillion
        self.cacheReadPerMillion = cacheReadPerMillion ?? inputPerMillion * 0.1
    }
}

public struct LinuxModelPricing: Sendable {
    public let rates: [String: LinuxModelRates]

    public init(rates: [String: LinuxModelRates] = [:]) { self.rates = rates }

    public func cost(model: String, tokens: LinuxTokenBreakdown) -> Double? {
        guard let rate = rates[model] else { return nil }
        return (
            Double(tokens.input) * rate.inputPerMillion
                + Double(tokens.output) * rate.outputPerMillion
                + Double(tokens.cacheWrite5m) * rate.cacheWritePerMillion
                + Double(tokens.cacheWrite1h) * rate.inputPerMillion * 2
                + Double(tokens.cacheRead) * rate.cacheReadPerMillion
        ) / 1_000_000
    }
}

public enum PiLinuxError: Error, LocalizedError, Equatable, Sendable {
    case localDataTooLarge
    case tooManySessionFiles
    case unreadableSession

    public var errorDescription: String? {
        switch self {
        case .localDataTooLarge: "Pi session data exceeds the bounded local read limit."
        case .tooManySessionFiles: "Pi has more than 256 session files in the scan window."
        case .unreadableSession: "Pi session data could not be read."
        }
    }
}

public struct PiLinuxUsageScanner: Sendable {
    public static let maximumFileBytes = 512 * 1024
    public static let maximumTotalBytes = 8 * 1024 * 1024
    public static let maximumFiles = 256

    public let sessionsDirectory: URL
    private let pricing: LinuxModelPricing

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        pricing: LinuxModelPricing = LinuxModelPricing()
    ) {
        let home = environment["HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        if let explicit = piTrimmed(environment["PI_CODING_AGENT_SESSION_DIR"]) {
            sessionsDirectory = piURL(expandingHome: explicit, home: home)
        } else if let directory = piTrimmed(environment["PI_CODING_AGENT_DIR"]) {
            sessionsDirectory = piURL(expandingHome: directory, home: home).appendingPathComponent("sessions")
        } else {
            sessionsDirectory = home.appendingPathComponent(".pi/agent/sessions")
        }
        self.pricing = pricing
    }

    public static func cardID(forProvider provider: String) -> String? {
        [
            "anthropic": "claude",
            "claude-agent-sdk": "claude",
            "openai-codex": "codex",
            "cursor": "cursor",
            "zai": "zai",
            "zhipu": "zai",
            "google-antigravity": "antigravity",
            "github-copilot": "copilot",
        ][provider]
    }

    public static func widgetDescriptors(forCardID cardID: String) -> [WidgetDescriptor] {
        [
            WidgetDescriptor(id: "\(cardID).trend", title: "Usage Trend", metricLabel: "Usage Trend"),
            WidgetDescriptor(id: "\(cardID).today", title: "Today", metricLabel: "Today"),
            WidgetDescriptor(id: "\(cardID).yesterday", title: "Yesterday", metricLabel: "Yesterday"),
            WidgetDescriptor(id: "\(cardID).last30", title: "Last 30 Days", metricLabel: "Last 30 Days"),
        ]
    }

    public func scan(cardID: String, daysBack: Int = 30, now: Date = Date()) throws -> [UsageMetric] {
        let files = try sessionFiles()
        guard !files.isEmpty else { return [] }
        let calendar = Calendar.current
        let since = calendar.date(byAdding: .day, value: -daysBack, to: calendar.startOfDay(for: now)) ?? .distantPast
        var entries: [PiEntry] = []
        var bytesRead = 0
        for file in files {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Self.maximumFileBytes + 1
            guard size <= Self.maximumFileBytes else { throw PiLinuxError.localDataTooLarge }
            bytesRead += size
            guard bytesRead <= Self.maximumTotalBytes else { throw PiLinuxError.localDataTooLarge }
            let data: Data
            do { data = try piReadBounded(file, maximumBytes: Self.maximumFileBytes) }
            catch PiLinuxError.localDataTooLarge { throw PiLinuxError.localDataTooLarge }
            catch { throw PiLinuxError.unreadableSession }
            entries.append(contentsOf: parseFile(data))
        }

        var seen: Set<String> = []
        var totals: [String: (tokens: Int, cost: Double)] = [:]
        for entry in entries where entry.cardID == cardID && entry.timestamp >= since {
            if let id = entry.id, !seen.insert(id).inserted { continue }
            let cost: Double
            if let carried = entry.carriedCost, carried > 0 {
                cost = carried
            } else if let estimated = pricing.cost(model: entry.model, tokens: entry.tokens) {
                cost = estimated
            } else {
                continue
            }
            let day = linuxDayKey(entry.timestamp, calendar: calendar)
            var total = totals[day] ?? (0, 0)
            total.tokens += entry.reportedTotalTokens
            total.cost += cost
            totals[day] = total
        }
        return linuxSpendMetrics(totals: totals, now: now, calendar: calendar)
    }

    private func sessionFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: sessionsDirectory.path) else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "jsonl" {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            files.append(url)
            if files.count > Self.maximumFiles { throw PiLinuxError.tooManySessionFiles }
        }
        return files.sorted { $0.path < $1.path }
    }

    private func parseFile(_ data: Data) -> [PiEntry] {
        let marker = Data(#""usage":{"#.utf8)
        return data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            let lineData = Data(line)
            guard lineData.range(of: marker) != nil else { return nil }
            return parseLine(lineData)
        }
    }

    private func parseLine(_ data: Data) -> PiEntry? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "message",
              let timestamp = piDate(object["timestamp"] as? String),
              let message = object["message"] as? [String: Any],
              message["role"] as? String == "assistant",
              let provider = message["provider"] as? String,
              let cardID = Self.cardID(forProvider: provider),
              let usage = message["usage"] as? [String: Any]
        else { return nil }
        let cacheWrite = Int(linuxNumber(usage["cacheWrite"]) ?? 0)
        let cacheWrite1h = Int(linuxNumber(usage["cacheWrite1h"]) ?? 0)
        let cost = (usage["cost"] as? [String: Any]).flatMap { linuxNumber($0["total"]) }
        return PiEntry(
            id: piTrimmed(object["id"] as? String), timestamp: timestamp, cardID: cardID,
            model: piTrimmed(message["model"] as? String) ?? "",
            carriedCost: cost,
            tokens: LinuxTokenBreakdown(
                input: Int(linuxNumber(usage["input"]) ?? 0),
                cacheWrite5m: max(cacheWrite - cacheWrite1h, 0),
                cacheWrite1h: cacheWrite1h,
                cacheRead: Int(linuxNumber(usage["cacheRead"]) ?? 0),
                output: Int(linuxNumber(usage["output"]) ?? 0)
            ),
            reportedTotalTokens: Int(linuxNumber(usage["totalTokens"]) ?? 0)
        )
    }
}

private struct PiEntry: Sendable {
    let id: String?
    let timestamp: Date
    let cardID: String
    let model: String
    let carriedCost: Double?
    let tokens: LinuxTokenBreakdown
    let reportedTotalTokens: Int
}
