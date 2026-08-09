import Foundation
import OpenUsagePricingResources

public struct ModelRates: Sendable, Equatable {
    public var inputPerMillion: Double
    public var outputPerMillion: Double
    public var cacheWritePerMillion: Double
    public var cacheReadPerMillion: Double
    public var inputAbove200kPerMillion: Double?
    public var outputAbove200kPerMillion: Double?
    public var cacheWriteAbove200kPerMillion: Double?
    public var cacheReadAbove200kPerMillion: Double?
    public var cacheReadIsExplicit: Bool
    public var longContextThresholdTokens: Int
    public var fastMultiplier: Double

    public init(inputPerMillion: Double, outputPerMillion: Double, cacheWritePerMillion: Double,
                cacheReadPerMillion: Double, inputAbove200kPerMillion: Double? = nil,
                outputAbove200kPerMillion: Double? = nil, cacheWriteAbove200kPerMillion: Double? = nil,
                cacheReadAbove200kPerMillion: Double? = nil, cacheReadIsExplicit: Bool = true,
                longContextThresholdTokens: Int = 200_000, fastMultiplier: Double = 1) {
        self.inputPerMillion = inputPerMillion; self.outputPerMillion = outputPerMillion
        self.cacheWritePerMillion = cacheWritePerMillion; self.cacheReadPerMillion = cacheReadPerMillion
        self.inputAbove200kPerMillion = inputAbove200kPerMillion; self.outputAbove200kPerMillion = outputAbove200kPerMillion
        self.cacheWriteAbove200kPerMillion = cacheWriteAbove200kPerMillion; self.cacheReadAbove200kPerMillion = cacheReadAbove200kPerMillion
        self.cacheReadIsExplicit = cacheReadIsExplicit; self.longContextThresholdTokens = longContextThresholdTokens
        self.fastMultiplier = fastMultiplier
    }

    public func costDollars(for tokens: TokenBreakdown, applyLongContextRates: Bool = true) -> Double {
        let long = applyLongContextRates && tokens.promptTokens > longContextThresholdTokens
        func selected(_ base: Double, _ elevated: Double?) -> Double { long ? (elevated ?? base) : base }
        func cost(_ count: Int, _ rate: Double) -> Double { Double(max(0, count)) * rate / 1_000_000 }
        let result = cost(tokens.input, selected(inputPerMillion, inputAbove200kPerMillion))
            + cost(tokens.output, selected(outputPerMillion, outputAbove200kPerMillion))
            + cost(tokens.cacheWrite5m, selected(cacheWritePerMillion, cacheWriteAbove200kPerMillion))
            + cost(tokens.cacheWrite1h, selected(inputPerMillion, inputAbove200kPerMillion) * 2)
            + cost(tokens.cacheRead, selected(cacheReadPerMillion, cacheReadAbove200kPerMillion))
        return result * (tokens.isFast ? fastMultiplier : 1)
    }

    fileprivate func scaled(by factor: Double) -> ModelRates {
        ModelRates(inputPerMillion: inputPerMillion * factor, outputPerMillion: outputPerMillion * factor,
            cacheWritePerMillion: cacheWritePerMillion * factor, cacheReadPerMillion: cacheReadPerMillion * factor,
            inputAbove200kPerMillion: inputAbove200kPerMillion.map { $0 * factor },
            outputAbove200kPerMillion: outputAbove200kPerMillion.map { $0 * factor },
            cacheWriteAbove200kPerMillion: cacheWriteAbove200kPerMillion.map { $0 * factor },
            cacheReadAbove200kPerMillion: cacheReadAbove200kPerMillion.map { $0 * factor },
            cacheReadIsExplicit: cacheReadIsExplicit, longContextThresholdTokens: longContextThresholdTokens)
    }
}

public struct TokenBreakdown: Codable, Sendable, Equatable {
    public var input: Int
    public var cacheWrite5m: Int
    public var cacheWrite1h: Int
    public var cacheRead: Int
    public var output: Int
    public var isFast: Bool

    public init(input: Int = 0, cacheWrite5m: Int = 0, cacheWrite1h: Int = 0,
                cacheRead: Int = 0, output: Int = 0, isFast: Bool = false) {
        self.input = input; self.cacheWrite5m = cacheWrite5m; self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead; self.output = output; self.isFast = isFast
    }
    public var promptTokens: Int { input + cacheWrite5m + cacheWrite1h + cacheRead }
    public var totalTokens: Int { promptTokens + output }
}

public struct PricingCatalog: Sendable, Equatable {
    public var entries: [String: ModelRates]
    public var retrievedAt: String?
    public init(entries: [String: ModelRates] = [:], retrievedAt: String? = nil) {
        self.entries = entries; self.retrievedAt = retrievedAt
    }
    fileprivate func exact(_ model: String) -> (String, ModelRates)? { entries[model].map { (model, $0) } }
    fileprivate func fuzzy(_ model: String) -> (String, ModelRates)? {
        let normalized = Self.normalized(model)
        return entries.compactMap { key, rates -> (String, ModelRates)? in
            let candidate = Self.normalized(key)
            return Self.contains(normalized, candidate) || Self.contains(candidate, normalized) ? (key, rates) : nil
        }.sorted { lhs, rhs in lhs.0.count == rhs.0.count ? lhs.0 < rhs.0 : lhs.0.count > rhs.0.count }.first
    }
    fileprivate static func normalized(_ value: String) -> String {
        value.replacingOccurrences(of: ".", with: "-").replacingOccurrences(of: "@", with: "-")
    }
    private static func contains(_ value: String, _ key: String) -> Bool {
        guard !key.isEmpty else { return false }
        let valueBytes = Array(value.utf8), keyBytes = Array(key.utf8)
        guard keyBytes.count <= valueBytes.count else { return false }
        for start in 0...(valueBytes.count - keyBytes.count) {
            guard valueBytes[start..<(start + keyBytes.count)].elementsEqual(keyBytes) else { continue }
            let beforeOK = start == 0 || !isAlphanumeric(valueBytes[start - 1])
            guard beforeOK else { continue }
            let suffix = Array(valueBytes[(start + keyBytes.count)...])
            guard let separator = suffix.first else { return true }
            guard !isAlphanumeric(separator) else { continue }
            if let last = keyBytes.last, last >= 48 && last <= 57,
               separator == UInt8(ascii: "-") || separator == UInt8(ascii: ".") {
                let digits = suffix.dropFirst().prefix { $0 >= 48 && $0 <= 57 }.count
                let next = suffix.dropFirst(1 + digits).first
                let dateSuffix = digits == 8 && (next.map { !isAlphanumeric($0) } ?? true)
                if digits > 0 && !dateSuffix { continue }
            }
            return true
        }
        return false
    }
    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
    }
}

public struct PricingSupplement: @unchecked Sendable {
    public struct AliasRule: @unchecked Sendable {
        fileprivate let expression: NSRegularExpression
        public let canonical: String
        public init(pattern: String, canonical: String) throws {
            expression = try NSRegularExpression(pattern: pattern); self.canonical = canonical
        }
    }
    public let pricing: [String: ModelRates]
    public let fastMultipliers: [String: Double]
    public let aliasRules: [AliasRule]
    public let updatedAt: String?
    public init(pricing: [String: ModelRates] = [:], fastMultipliers: [String: Double] = [:],
                aliasRules: [AliasRule] = [], updatedAt: String? = nil) {
        self.pricing = pricing; self.fastMultipliers = fastMultipliers; self.aliasRules = aliasRules; self.updatedAt = updatedAt
    }
    public func canonicalName(for model: String) -> String? {
        let range = NSRange(model.startIndex..., in: model)
        return aliasRules.first { $0.expression.firstMatch(in: model, range: range) != nil }?.canonical
    }
    fileprivate func fastMultiplier(for model: String) -> Double? {
        if let exact = fastMultipliers[model] { return exact }
        let normalized = PricingCatalog.normalized(model)
        return fastMultipliers.first { normalized == PricingCatalog.normalized($0.key)
            || normalized.hasSuffix("-" + PricingCatalog.normalized($0.key)) }?.value
    }
}

public final class ModelPricing: @unchecked Sendable {
    public let supplement: PricingSupplement
    public let primary: PricingCatalog
    public let secondary: PricingCatalog
    private let lock = NSLock()
    private var memo: [String: ModelRates?] = [:]

    public init(supplement: PricingSupplement, primary: PricingCatalog, secondary: PricingCatalog) {
        self.supplement = supplement; self.primary = primary; self.secondary = secondary
    }

    public static func bundled() throws -> ModelPricing {
        func data(_ name: String) throws -> Data {
            do { return try LinuxPricingResources.data(named: name) }
            catch { throw PricingResourceError.missing(name) }
        }
        return ModelPricing(
            supplement: try PricingDecoder.supplement(data("pricing_supplement")),
            primary: try PricingDecoder.compact(data("pricing_litellm_snapshot")),
            secondary: try PricingDecoder.compact(data("pricing_models_dev_snapshot"))
        )
    }

    public func resolve(model: String) -> ModelRates? {
        lock.lock(); if let cached = memo[model] { lock.unlock(); return cached }; lock.unlock()
        let canonical = supplement.canonicalName(for: model)
        let result = canonical.flatMap(lookup) ?? lookup(model)
        lock.lock(); memo[model] = result; lock.unlock()
        return result
    }
    public func estimatedCostDollars(model: String, tokens: TokenBreakdown,
                                     applyLongContextRates: Bool = true) -> Double? {
        resolve(model: model)?.costDollars(for: tokens, applyLongContextRates: applyLongContextRates)
    }
    private func lookup(_ name: String) -> ModelRates? {
        if let value = supplement.pricing[name] { return value }
        if let value = primary.exact(name)?.1 { return value }
        if name.hasSuffix("-fast") {
            let base = String(name.dropLast(5))
            if let pair = supplement.pricing[base].map({ (base, $0) }) ?? primary.exact(base) ?? primary.fuzzy(base) ?? secondary.exact(base),
               let multiplier = pair.1.fastMultiplier != 1 ? pair.1.fastMultiplier : supplement.fastMultiplier(for: pair.0) {
                return pair.1.scaled(by: multiplier)
            }
            return secondary.exact(name)?.1
        }
        return primary.fuzzy(name)?.1 ?? secondary.exact(name)?.1
    }
}

public enum PricingResourceError: Error, Equatable { case missing(String); case invalid }

private enum PricingDecoder {
    struct Compact: Decodable { let retrievedAt: String?; let models: [String: CompactRate]
        enum CodingKeys: String, CodingKey { case retrievedAt = "retrieved_at", models } }
    struct CompactRate: Decodable { let i: Double; let o: Double; let cw: Double; let cr: Double
        let ia: Double?; let oa: Double?; let cwa: Double?; let cra: Double?; let cre: Bool?; let fast: Double? }
    struct SupplementFile: Decodable { let updatedAt: String?; let pricing: [String: SupplementRate]
        let fastMultipliers: [String: Double]?; let aliasRules: [Rule]
        enum CodingKeys: String, CodingKey { case updatedAt = "updated_at", pricing
            case fastMultipliers = "fast_multipliers"; case aliasRules = "alias_rules" } }
    struct SupplementRate: Decodable { let input: Double; let output: Double; let cacheWrite: Double?; let cacheRead: Double?
        enum CodingKeys: String, CodingKey { case input = "input_per_million"; case output = "output_per_million"
            case cacheWrite = "cache_write_per_million"; case cacheRead = "cache_read_per_million" } }
    struct Rule: Decodable { let pattern: String; let canonical: String }

    static func compact(_ data: Data) throws -> PricingCatalog {
        let decoded = try JSONDecoder().decode(Compact.self, from: data)
        return PricingCatalog(entries: decoded.models.mapValues { value in
            ModelRates(inputPerMillion: value.i, outputPerMillion: value.o, cacheWritePerMillion: value.cw,
                cacheReadPerMillion: value.cr, inputAbove200kPerMillion: value.ia,
                outputAbove200kPerMillion: value.oa, cacheWriteAbove200kPerMillion: value.cwa,
                cacheReadAbove200kPerMillion: value.cra, cacheReadIsExplicit: value.cre ?? true,
                fastMultiplier: value.fast ?? 1)
        }, retrievedAt: decoded.retrievedAt)
    }
    static func supplement(_ data: Data) throws -> PricingSupplement {
        let decoded = try JSONDecoder().decode(SupplementFile.self, from: data)
        return PricingSupplement(pricing: decoded.pricing.mapValues { value in
            ModelRates(inputPerMillion: value.input, outputPerMillion: value.output,
                cacheWritePerMillion: value.cacheWrite ?? value.input,
                cacheReadPerMillion: value.cacheRead ?? value.input * 0.1,
                cacheReadIsExplicit: value.cacheRead != nil)
        }, fastMultipliers: decoded.fastMultipliers ?? [:],
        aliasRules: decoded.aliasRules.compactMap { try? PricingSupplement.AliasRule(pattern: $0.pattern, canonical: $0.canonical) },
        updatedAt: decoded.updatedAt)
    }
}
