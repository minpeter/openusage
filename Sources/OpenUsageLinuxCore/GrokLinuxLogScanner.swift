import Foundation

public struct GrokLinuxLogScanner: Sendable {
    public static let maximumReadBytes = 512 * 1024
    public let logURL: URL
    private let pricing: LinuxModelPricing

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        pricing: LinuxModelPricing = LinuxModelPricing()
    ) {
        let home = environment["HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let grokHome: URL
        if let raw = grokTrimmed(environment["GROK_HOME"]) {
            grokHome = raw.hasPrefix("~/")
                ? home.appendingPathComponent(String(raw.dropFirst(2)))
                : URL(fileURLWithPath: raw)
        } else { grokHome = home.appendingPathComponent(".grok") }
        self.logURL = grokHome.appendingPathComponent("logs/unified.jsonl")
        self.pricing = pricing
    }

    public func scan(daysBack: Int = 30, now: Date = Date()) throws -> [UsageMetric] {
        guard FileManager.default.fileExists(atPath: logURL.path) else { return [] }
        let data = try grokReadBounded(logURL, maximumBytes: Self.maximumReadBytes)
        guard let text = String(data: data, encoding: .utf8) else { throw GrokLinuxError.invalidResponse }
        var models: [Int: String] = [:]
        var totals: [String: (tokens: Int, cost: Double)] = [:]
        let calendar = Calendar.current
        let since = calendar.date(byAdding: .day, value: -daysBack, to: calendar.startOfDay(for: now)) ?? .distantPast
        text.enumerateLines { line, _ in
            guard (line.contains("model") || line.contains("inference_done")),
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let message = object["msg"] as? String
            else { return }
            let context = object["ctx"] as? [String: Any] ?? [:]
            let pid = linuxNumber(object["pid"]).map(Int.init)
            let rawModel: String? = switch message {
            case "model changed": context["model"] as? String
            case "model catalog: notifying clients": context["current_model_id"] as? String
            case "backend_search: model switch":
                (context["model"] ?? context["current_model_id"] ?? context["model_id"]) as? String
            case "subagent model resolved": (context["model_id"] ?? context["model"]) as? String
            default: nil
            }
            if let pid, let model = grokTrimmed(rawModel) {
                models[pid] = model
                return
            }
            guard message == "shell.turn.inference_done", let pid, let model = models[pid],
                  let timestamp = grokDate(object["ts"] as? String), timestamp >= since,
                  let prompt = linuxNumber(context["prompt_tokens"])
            else { return }
            let cached = min(linuxNumber(context["cached_prompt_tokens"]) ?? 0, prompt)
            let completion = linuxNumber(context["completion_tokens"]) ?? 0
            let reasoning = linuxNumber(context["reasoning_tokens"]) ?? 0
            let tokens = LinuxTokenBreakdown(
                input: Int(max(prompt - cached, 0)), cacheRead: Int(cached), output: Int(completion + reasoning)
            )
            guard let cost = pricing.cost(model: model, tokens: tokens) else { return }
            let day = linuxDayKey(timestamp, calendar: calendar)
            var total = totals[day] ?? (0, 0)
            total.tokens += Int(prompt + completion + reasoning)
            total.cost += cost
            totals[day] = total
        }
        return linuxSpendMetrics(totals: totals, now: now, calendar: calendar)
    }
}
