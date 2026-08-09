import Foundation

public struct CodexLocalLogScanner: Sendable {
    private let environment: [String: String]
    private let homeDirectory: URL

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.environment = environment; self.homeDirectory = homeDirectory
    }

    public func scan(now: Date = Date(), daysBack: Int = 30, pricing: ModelPricing,
                     calendar: Calendar = .current) throws -> LocalUsageScan? {
        let homes: [URL]
        if let raw = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            homes = raw.split(separator: ",").map {
                let path = String($0).trimmingCharacters(in: .whitespaces)
                if path == "~" { return homeDirectory }
                if path.hasPrefix("~/") { return homeDirectory.appendingPathComponent(String(path.dropFirst(2))) }
                return URL(fileURLWithPath: path)
            }
        } else { homes = [homeDirectory.appendingPathComponent(".codex")] }
        return try scan(homes: homes, now: now, daysBack: daysBack, pricing: pricing, calendar: calendar)
    }

    private struct Event { let timestamp: Date; let model: String; let input: Int; let cached: Int
        let output: Int; let reasoning: Int; let total: Int; let fast: Bool }
    private struct EventKey: Hashable { let timestamp: Date; let model: String; let input: Int; let cached: Int
        let output: Int; let reasoning: Int; let total: Int }
    private struct Raw: Equatable { let input: Int; let cached: Int; let output: Int; let reasoning: Int; let total: Int
        init(_ json: [String: Any]) {
            func value(_ keys: String...) -> Int { keys.compactMap { localLogNumber(json[$0]).map(localLogNonnegativeInt) }.first ?? 0 }
            input = value("input_tokens", "prompt_tokens", "input"); cached = value("cached_input_tokens", "cache_read_input_tokens", "cached_tokens")
            output = value("output_tokens", "completion_tokens", "output"); reasoning = value("reasoning_output_tokens", "reasoning_tokens")
            let reported = value("total_tokens"); let computed = input + output + reasoning; total = reported > 0 ? reported : computed
        }
        func subtracting(_ old: Raw?) -> Raw {
            Raw(input: max(0, input - (old?.input ?? 0)), cached: max(0, cached - (old?.cached ?? 0)),
                output: max(0, output - (old?.output ?? 0)), reasoning: max(0, reasoning - (old?.reasoning ?? 0)),
                total: max(0, total - (old?.total ?? 0)))
        }
        private init(input: Int, cached: Int, output: Int, reasoning: Int, total: Int) {
            self.input = input; self.cached = cached; self.output = output; self.reasoning = reasoning; self.total = total
        }
    }

    public func scan(homes: [URL], now: Date = Date(), daysBack: Int = 30,
                     pricing: ModelPricing, calendar: Calendar = .current) throws -> LocalUsageScan? {
        let files = sessionFiles(homes)
        guard !files.isEmpty else { return nil }
        let lowerBound = localLogSince(now: now, daysBack: daysBack, calendar: calendar)
        var events: [Event] = []; events.reserveCapacity(min(2_048, BoundedJSONL.maximumEvents))
        for file in files {
            try parse(file) { event in
                guard event.timestamp >= lowerBound && event.timestamp <= now else { return }
                guard events.count < BoundedJSONL.maximumEvents else { throw LocalLogScanError.tooManyEvents(maximum: BoundedJSONL.maximumEvents) }
                events.append(event)
            }
        }
        let result = aggregate(events, since: lowerBound,
                               pricing: pricing, calendar: calendar)
        return LocalUsageHistory.merge([result], now: now, calendar: calendar)
    }

    private func sessionFiles(_ homes: [URL]) -> [URL] {
        var files: [URL] = []
        for home in homes {
            let active = BoundedJSONL.jsonlFiles(under: home.appendingPathComponent("sessions"))
            let archived = BoundedJSONL.jsonlFiles(under: home.appendingPathComponent("archived_sessions"))
            if active.isEmpty && archived.isEmpty { files += BoundedJSONL.jsonlFiles(under: home); continue }
            let activeRoot = home.appendingPathComponent("sessions").path
            var relative = Set(active.map { String($0.path.dropFirst(activeRoot.count)) })
            files += active
            let archiveRoot = home.appendingPathComponent("archived_sessions").path
            files += archived.filter { relative.insert(String($0.path.dropFirst(archiveRoot.count))).inserted }
        }
        return files.sorted { $0.path < $1.path }
    }

    private func parse(_ file: URL, emit: (Event) throws -> Void) throws {
        var previous: Raw?; var model: String?; var fast = false; var sawMeta = false
        var childCreated: TimeInterval?; var childWithoutTime = false
        try BoundedJSONL.lines(at: file) { line in
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = object["type"] as? String else { return }
            let payload = object["payload"] as? [String: Any]
            if type == "turn_context" { if let value = modelName(payload) { model = value }; return }
            if type == "session_meta", !sawMeta {
                sawMeta = true
                if isChild(payload) {
                    if let date = localLogISODate(object["timestamp"]) { childCreated = floor(date.timeIntervalSince1970) }
                    else { childWithoutTime = true }
                }
                return
            }
            if type == "event_msg", payload?["type"] as? String == "thread_settings_applied" {
                let settings = payload?["thread_settings"] as? [String: Any]
                if let tier = settings?["service_tier"] as? String ?? payload?["service_tier"] as? String {
                    fast = tier == "fast" || tier == "priority"
                }
                return
            }
            guard type == "event_msg", let payload else { return }
            if payload["type"] as? String == "task_started" {
                if let started = localLogNumber(payload["started_at"]) {
                    if let created = childCreated, started >= created { childCreated = nil }
                    else if childWithoutTime, let date = localLogISODate(object["timestamp"]), started >= floor(date.timeIntervalSince1970) { childWithoutTime = false }
                }
                return
            }
            guard payload["type"] as? String == "token_count", let timestamp = localLogISODate(object["timestamp"]) else { return }
            let info = payload["info"] as? [String: Any]
            let totals = (info?["total_token_usage"] as? [String: Any]).map(Raw.init)
            if childCreated != nil || childWithoutTime { if let totals { previous = totals }; return }
            if let totals, totals == previous { return }
            let usage = (info?["last_token_usage"] as? [String: Any]).map(Raw.init) ?? totals?.subtracting(previous)
            if let totals { previous = totals }
            guard let usage, usage.input > 0 || usage.cached > 0 || usage.output > 0 || usage.reasoning > 0 else { return }
            if let inline = modelName(payload) ?? modelName(info) { model = inline }
            var resolved = model ?? "gpt-5"
            if resolved == "codex-auto-review" { resolved = autoReview(timestamp) }
            try emit(Event(timestamp: timestamp, model: resolved, input: usage.input,
                cached: min(usage.cached, usage.input), output: usage.output, reasoning: usage.reasoning,
                total: usage.total, fast: fast))
        }
    }

    private func aggregate(_ events: [Event], since: Date, pricing: ModelPricing,
                           calendar: Calendar) -> LocalUsageScan {
        var seen: Set<EventKey> = []; var days: [String: LocalUsageHistory.Accumulator] = [:]
        var unknown: [String: Set<String>] = [:]
        for event in events where event.timestamp >= since {
            let key = EventKey(timestamp: event.timestamp, model: event.model, input: event.input,
                cached: event.cached, output: event.output, reasoning: event.reasoning, total: event.total)
            guard seen.insert(key).inserted else { continue }
            let day = LocalUsageHistory.dayKey(event.timestamp, calendar: calendar)
            let canonical = pricing.supplement.canonicalName(for: event.model) ?? event.model
            let isFastAlias = canonical.hasSuffix("-fast")
            let rateModel = isFastAlias ? String(canonical.dropLast("-fast".count)) : canonical
            let baseRates = pricing.resolve(model: rateModel)
            guard var rates = baseRates ?? pricing.resolve(model: event.model) else {
                if event.total > 0 { unknown[day, default: []].insert(event.model) }; continue
            }
            applyCodexLongContextRates(model: rateModel, rates: &rates)
            if !rates.cacheReadIsExplicit || codexModelHasNoCacheDiscount(rateModel) {
                rates.cacheReadPerMillion = rates.inputPerMillion
                rates.cacheReadAbove200kPerMillion = rates.inputAbove200kPerMillion
            }
            let fastTier = isFastAlias ? baseRates != nil : event.fast
            if fastTier { rates.fastMultiplier = codexFastMultiplier(model: rateModel, fallback: rates.fastMultiplier) }
            let cost = rates.costDollars(for: TokenBreakdown(input: max(0, event.input - event.cached),
                cacheRead: event.cached, output: event.output, isFast: fastTier))
            guard cost.isFinite, cost >= 0 else { continue }
            days[day, default: .init()].add(tokens: event.total, cost: cost, model: event.model)
        }
        return LocalUsageScan(daily: days.map { $1.day(date: $0) }.sorted { $0.date > $1.date }, unknownModelsByDay: unknown)
    }

    private func isChild(_ payload: [String: Any]?) -> Bool {
        guard let payload else { return false }
        func present(_ value: Any?) -> Bool { value != nil && !(value is NSNull) && ((value as? String)?.isEmpty != true) }
        return present(payload["forked_from_id"]) || present(payload["parent_thread_id"])
            || payload["thread_source"] as? String == "subagent"
            || present((payload["source"] as? [String: Any])?["subagent"])
    }
    private func modelName(_ json: [String: Any]?) -> String? {
        guard let json else { return nil }
        for value in [json["model"], json["model_name"], (json["metadata"] as? [String: Any])?["model"]] {
            if let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }
        return nil
    }
    private func applyCodexLongContextRates(model: String, rates: inout ModelRates) {
        let values: (Double, Double, Double)?
        switch datedBase(model) {
        case "gpt-5.4": values = (5, 22.5, 0.5)
        case "gpt-5.4-pro", "gpt-5.5-pro": values = (60, 270, 60)
        case "gpt-5.5", "gpt-5.6-sol": values = (10, 45, 1)
        case "gpt-5.6-terra": values = (5, 22.5, 0.5)
        case "gpt-5.6-luna": values = (2, 9, 0.2)
        default: values = nil
        }
        guard let values else { return }
        rates.inputAbove200kPerMillion = values.0; rates.outputAbove200kPerMillion = values.1
        rates.cacheReadAbove200kPerMillion = values.2; rates.longContextThresholdTokens = 272_000
    }
    private func codexModelHasNoCacheDiscount(_ model: String) -> Bool {
        ["gpt-5.4-pro", "gpt-5.5-pro"].contains(datedBase(model))
    }
    private func datedBase(_ model: String) -> String {
        model.replacingOccurrences(of: #"-\d{4}-\d{2}-\d{2}$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
    }
    private func codexFastMultiplier(model: String, fallback: Double) -> Double {
        switch datedBase(model) {
        case "gpt-5.5", "gpt-5.5-pro": return 2.5
        case "gpt-5.4", "gpt-5.4-pro", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna": return 2
        default: return fallback == 1 ? 2 : fallback
        }
    }

    private func autoReview(_ date: Date) -> String {
        let releases: [(TimeInterval, String)] = [
            (1_777_161_600, "gpt-5.5"), (1_772_668_800, "gpt-5.4"), (1_770_249_600, "gpt-5.3-codex"),
            (1_765_411_200, "gpt-5.2-codex"), (1_763_001_600, "gpt-5.1-codex"),
            (1_757_894_400, "gpt-5-codex"), (1_754_524_800, "gpt-5")]
        return releases.first { date.timeIntervalSince1970 >= $0.0 }?.1 ?? "gpt-5"
    }
}
