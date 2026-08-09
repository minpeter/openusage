import Foundation

public struct ClaudeLocalLogScanner: Sendable {
    private let environment: [String: String]
    private let homeDirectory: URL

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.environment = environment; self.homeDirectory = homeDirectory
    }

    public func scan(now: Date = Date(), daysBack: Int = 30, pricing: ModelPricing,
                     calendar: Calendar = .current) throws -> LocalUsageScan? {
        let roots: [URL]
        if let raw = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            roots = raw.split(separator: ",").map {
                let path = String($0).trimmingCharacters(in: .whitespaces)
                let expanded = path == "~" ? homeDirectory.path
                    : path.hasPrefix("~/") ? homeDirectory.appendingPathComponent(String(path.dropFirst(2))).path : path
                var url = URL(fileURLWithPath: expanded)
                if url.lastPathComponent == "projects" { url.deleteLastPathComponent() }
                return url
            }
        } else {
            let xdg = environment["XDG_CONFIG_HOME"].map(URL.init(fileURLWithPath:))
                ?? homeDirectory.appendingPathComponent(".config")
            roots = [xdg.appendingPathComponent("claude"), homeDirectory.appendingPathComponent(".claude")]
        }
        return try scan(configDirectories: roots, now: now, daysBack: daysBack, pricing: pricing, calendar: calendar)
    }

    private struct Entry {
        let timestamp: Date
        let tokens: TokenBreakdown
        let messageID: String?
        let requestID: String?
        let sidechain: Bool
        let hasSpeed: Bool
        let cost: Double?
        let model: String?
    }
    private struct Key: Hashable { let message: String; let request: String? }

    public func scan(configDirectories: [URL], now: Date = Date(), daysBack: Int = 30,
                     pricing: ModelPricing, calendar: Calendar = .current) throws -> LocalUsageScan? {
        let roots = configDirectories.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("projects").path) }
        let files = roots.flatMap { BoundedJSONL.jsonlFiles(under: $0.appendingPathComponent("projects")) }
            .sorted { $0.path < $1.path }
        guard !files.isEmpty else { return nil }
        let lowerBound = localLogSince(now: now, daysBack: daysBack, calendar: calendar)
        var entries: [Entry] = []; entries.reserveCapacity(min(2_048, BoundedJSONL.maximumEvents))
        for file in files {
            try BoundedJSONL.lines(at: file) { line in
                guard line.range(of: Data(#""usage""#.utf8)) != nil,
                      let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
                else { return }
                for entry in parse(object) where entry.timestamp >= lowerBound && entry.timestamp <= now {
                    guard entries.count < BoundedJSONL.maximumEvents else {
                        throw LocalLogScanError.tooManyEvents(maximum: BoundedJSONL.maximumEvents)
                    }
                    entries.append(entry)
                }
            }
        }
        let result = aggregate(deduplicate(entries), since: lowerBound,
                               pricing: pricing, calendar: calendar)
        return LocalUsageHistory.merge([result], now: now, calendar: calendar)
    }

    private func parse(_ object: [String: Any]) -> [Entry] {
        guard let timestamp = localLogISODate(object["timestamp"]),
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              !hasUnsupportedNull(object: object, message: message, usage: usage),
              let parentTokens = tokens(usage), valid(object: object, message: message) else { return [] }
        let speed = usage["speed"] as? String
        let model = (message["model"] as? String).flatMap { $0 == "<synthetic>" ? nil : $0 }
        let parent = Entry(timestamp: timestamp, tokens: parentTokens, messageID: message["id"] as? String,
            requestID: object["requestId"] as? String, sidechain: object["isSidechain"] as? Bool ?? false,
            hasSpeed: speed != nil, cost: localLogNumber(object["costUSD"]), model: model)
        guard let iterations = usage["iterations"] as? [[String: Any]] else { return [parent] }
        var result = [parent]; var index = 0
        for iteration in iterations where iteration["type"] as? String == "advisor_message" {
            guard let model = iteration["model"] as? String, !model.isEmpty, let usage = tokens(iteration) else { continue }
            result.append(Entry(timestamp: timestamp, tokens: usage,
                messageID: parent.messageID.map { "\($0):advisor:\(index)" }, requestID: parent.requestID,
                sidechain: parent.sidechain, hasSpeed: iteration["speed"] != nil, cost: nil, model: model))
            index += 1
        }
        return result
    }

    private func tokens(_ usage: [String: Any]) -> TokenBreakdown? {
        guard let input = localLogNumber(usage["input_tokens"]), let output = localLogNumber(usage["output_tokens"]) else { return nil }
        let speed = usage["speed"] as? String
        guard speed == nil || speed == "fast" || speed == "standard" else { return nil }
        let creation = usage["cache_creation"] as? [String: Any]
        return TokenBreakdown(input: localLogNonnegativeInt(input),
            cacheWrite5m: localLogNonnegativeInt(localLogNumber(creation?["ephemeral_5m_input_tokens"])
                ?? localLogNumber(usage["cache_creation_input_tokens"]) ?? 0),
            cacheWrite1h: localLogNonnegativeInt(localLogNumber(creation?["ephemeral_1h_input_tokens"]) ?? 0),
            cacheRead: localLogNonnegativeInt(localLogNumber(usage["cache_read_input_tokens"]) ?? 0),
            output: localLogNonnegativeInt(output), isFast: speed == "fast")
    }

    private func hasUnsupportedNull(object: [String: Any], message: [String: Any], usage: [String: Any]) -> Bool {
        ["sessionId", "requestId", "costUSD", "version", "isApiErrorMessage"].contains { object[$0] is NSNull }
            || ["id", "model"].contains { message[$0] is NSNull }
            || ["speed", "cache_read_input_tokens", "cache_creation_input_tokens"].contains { usage[$0] is NSNull }
    }

    private func valid(object: [String: Any], message: [String: Any]) -> Bool {
        if let version = object["version"] as? String,
           version.range(of: #"^\d+\.\d+\.\d+"#, options: .regularExpression) == nil { return false }
        for value in [object["sessionId"], object["requestId"], message["id"], message["model"]]
            where (value as? String)?.isEmpty == true { return false }
        return true
    }

    private func deduplicate(_ source: [Entry]) -> [Entry] {
        var result: [Entry] = []; var exact: [Key: Int] = [:]; var byMessage: [String: [Int]] = [:]
        for entry in source {
            guard let message = entry.messageID else { result.append(entry); continue }
            let key = Key(message: message, request: entry.requestID)
            let collision = exact[key] ?? byMessage[message]?.first { entry.sidechain || result[$0].sidechain }
            if let index = collision {
                let existing = result[index]
                let replace = existing.sidechain != entry.sidechain ? existing.sidechain
                    : existing.tokens.totalTokens != entry.tokens.totalTokens ? entry.tokens.totalTokens > existing.tokens.totalTokens
                    : entry.hasSpeed && !existing.hasSpeed
                if replace { result[index] = entry; exact[key] = index }
            } else {
                exact[key] = result.count; byMessage[message, default: []].append(result.count); result.append(entry)
            }
        }
        return result
    }

    private func aggregate(_ entries: [Entry], since: Date, pricing: ModelPricing,
                           calendar: Calendar) -> LocalUsageScan {
        var days: [String: LocalUsageHistory.Accumulator] = [:]; var unknown: [String: Set<String>] = [:]
        for entry in entries where entry.timestamp >= since {
            let day = LocalUsageHistory.dayKey(entry.timestamp, calendar: calendar)
            let model = entry.model?.trimmingCharacters(in: .whitespacesAndNewlines)
            let cost = entry.cost.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
                ?? model.flatMap { pricing.estimatedCostDollars(model: $0, tokens: entry.tokens) }
            guard let cost, cost.isFinite, cost >= 0 else {
                if let model, !model.isEmpty, entry.tokens.totalTokens > 0 { unknown[day, default: []].insert(model) }
                continue
            }
            days[day, default: .init()].add(tokens: entry.tokens.totalTokens, cost: cost,
                model: model?.isEmpty == false ? model! : "Unattributed")
        }
        return LocalUsageScan(daily: days.map { $1.day(date: $0) }.sorted { $0.date > $1.date }, unknownModelsByDay: unknown)
    }
}
