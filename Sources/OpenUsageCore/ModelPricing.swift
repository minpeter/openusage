import Foundation

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

    public init(
        inputPerMillion: Double,
        outputPerMillion: Double,
        cacheWritePerMillion: Double,
        cacheReadPerMillion: Double,
        inputAbove200kPerMillion: Double? = nil,
        outputAbove200kPerMillion: Double? = nil,
        cacheWriteAbove200kPerMillion: Double? = nil,
        cacheReadAbove200kPerMillion: Double? = nil,
        cacheReadIsExplicit: Bool = true,
        longContextThresholdTokens: Int = 200_000,
        fastMultiplier: Double = 1)
    {
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
        self.cacheWritePerMillion = cacheWritePerMillion
        self.cacheReadPerMillion = cacheReadPerMillion
        self.inputAbove200kPerMillion = inputAbove200kPerMillion
        self.outputAbove200kPerMillion = outputAbove200kPerMillion
        self.cacheWriteAbove200kPerMillion = cacheWriteAbove200kPerMillion
        self.cacheReadAbove200kPerMillion = cacheReadAbove200kPerMillion
        self.cacheReadIsExplicit = cacheReadIsExplicit
        self.longContextThresholdTokens = longContextThresholdTokens
        self.fastMultiplier = fastMultiplier
    }

    public func costDollars(
        for tokens: TokenBreakdown,
        applyLongContextRates: Bool = true
    ) -> Double {
        let useLong = applyLongContextRates
            && tokens.promptTokens > self.longContextThresholdTokens
        let inputRate = useLong ? self.inputAbove200kPerMillion ?? self.inputPerMillion
            : self.inputPerMillion
        let outputRate = useLong ? self.outputAbove200kPerMillion ?? self.outputPerMillion
            : self.outputPerMillion
        let writeRate = useLong ? self.cacheWriteAbove200kPerMillion
            ?? self.cacheWritePerMillion : self.cacheWritePerMillion
        let readRate = useLong ? self.cacheReadAbove200kPerMillion
            ?? self.cacheReadPerMillion : self.cacheReadPerMillion
        let million = 1_000_000.0
        let cacheWriteTokens = tokens.cacheWrite5m + tokens.cacheWrite1h
        let total = Double(tokens.input) / million * inputRate
            + Double(tokens.output) / million * outputRate
            + Double(cacheWriteTokens) / million * writeRate
            + Double(tokens.cacheRead) / million * readRate
        return total * (tokens.isFast ? self.fastMultiplier : 1)
    }

    public func scaled(by factor: Double) -> ModelRates {
        var copy = self
        copy.inputPerMillion *= factor
        copy.outputPerMillion *= factor
        copy.cacheWritePerMillion *= factor
        copy.cacheReadPerMillion *= factor
        copy.inputAbove200kPerMillion = copy.inputAbove200kPerMillion.map { $0 * factor }
        copy.outputAbove200kPerMillion = copy.outputAbove200kPerMillion.map { $0 * factor }
        copy.cacheWriteAbove200kPerMillion = copy.cacheWriteAbove200kPerMillion.map { $0 * factor }
        copy.cacheReadAbove200kPerMillion = copy.cacheReadAbove200kPerMillion.map { $0 * factor }
        return copy
    }
}

public struct TokenBreakdown: Codable, Sendable, Equatable {
    public var input: Int
    public var cacheWrite5m: Int
    public var cacheWrite1h: Int
    public var cacheRead: Int
    public var output: Int
    public var isFast: Bool

    public init(
        input: Int = 0,
        cacheWrite5m: Int = 0,
        cacheWrite1h: Int = 0,
        cacheRead: Int = 0,
        output: Int = 0,
        isFast: Bool = false)
    {
        self.input = input
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
        self.output = output
        self.isFast = isFast
    }

    public var promptTokens: Int {
        self.input + self.cacheWrite5m + self.cacheWrite1h + self.cacheRead
    }

    public var totalTokens: Int {
        self.promptTokens + self.output
    }
}

public struct PricingCatalog: Sendable, Equatable {
    public var entries: [String: ModelRates]
    public var retrievedAt: String?

    public init(entries: [String: ModelRates] = [:], retrievedAt: String? = nil) {
        self.entries = entries
        self.retrievedAt = retrievedAt
    }

    public func lookup(_ model: String) -> ModelRates? {
        let key = model.lowercased()
        if let exact = self.entries[key] {
            return exact
        }
        if let pair = self.entries.first(where: {
            Self.contains(key, $0.key.lowercased())
        }) {
            return pair.value
        }
        return self.entries.first(where: {
            Self.contains($0.key.lowercased(), key)
        })?.value
    }

    public func findExact(_ model: String) -> (key: String, rates: ModelRates)? {
        let normalized = Self.normalizedKey(model)
        guard let pair = self.entries.first(where: {
            Self.normalizedKey($0.key) == normalized
        }) else {
            return nil
        }
        return (key: pair.key, rates: pair.value)
    }

    public func findFuzzy(_ model: String) -> (key: String, rates: ModelRates)? {
        let normalized = Self.normalizedKey(model)
        guard let pair = self.entries.first(where: {
            Self.keyMatches(
                candidate: $0.key,
                model: model,
                normalizedModel: normalized)
        }) else {
            return nil
        }
        return (key: pair.key, rates: pair.value)
    }

    public func merging(_ other: PricingCatalog) -> PricingCatalog {
        var merged = self.entries
        for (key, value) in other.entries {
            merged[key] = value
        }
        return PricingCatalog(
            entries: merged,
            retrievedAt: other.retrievedAt ?? self.retrievedAt)
    }

    public static func normalizedKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    public static func keyMatches(
        candidate: String,
        model: String,
        normalizedModel: String
    ) -> Bool {
        let key = Self.normalizedKey(candidate)
        guard !key.isEmpty else {
            return false
        }
        if key == normalizedModel {
            return true
        }
        return Self.contains(model.lowercased(), key)
            || Self.contains(normalizedModel, key)
            || Self.contains(key, normalizedModel)
    }

    private static func contains(_ value: String, _ key: String) -> Bool {
        guard !key.isEmpty else {
            return false
        }
        var start = value.startIndex
        while start < value.endIndex,
              let range = value.range(of: key, range: start..<value.endIndex)
        {
            let leftOK = range.lowerBound == value.startIndex
                || !Self.isAlphanumeric(value[value.index(before: range.lowerBound)])
            let rightOK = range.upperBound == value.endIndex
                || !Self.isAlphanumeric(value[range.upperBound])
            if leftOK, rightOK {
                return true
            }
            start = value.index(after: range.lowerBound)
        }
        return false
    }

    private static func isAlphanumeric(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}

public struct PricingSupplement: @unchecked Sendable {
    public struct AliasRule: @unchecked Sendable {
        public let regex: NSRegularExpression
        public let canonical: String

        public init(regex: NSRegularExpression, canonical: String) {
            self.regex = regex
            self.canonical = canonical
        }

        public init(pattern: String, canonical: String) throws {
            self.regex = try NSRegularExpression(pattern: pattern)
            self.canonical = canonical
        }
    }

    public let pricing: [String: ModelRates]
    public let fastMultipliers: [String: Double]
    public let aliasRules: [AliasRule]
    public let updatedAt: String?

    public init(
        pricing: [String: ModelRates] = [:],
        fastMultipliers: [String: Double] = [:],
        aliasRules: [AliasRule] = [],
        updatedAt: String? = nil)
    {
        self.pricing = pricing
        self.fastMultipliers = fastMultipliers
        self.aliasRules = aliasRules
        self.updatedAt = updatedAt
    }

    public func canonicalName(for model: String) -> String? {
        let range = NSRange(model.startIndex..<model.endIndex, in: model)
        return self.aliasRules.first(where: {
            $0.regex.firstMatch(in: model, range: range) != nil
        })?.canonical
    }
}

public final class ModelPricing: @unchecked Sendable {
    public let supplement: PricingSupplement
    public let primary: PricingCatalog
    public let secondary: PricingCatalog
    private let lock = NSLock()
    private var memo: [String: ModelRates?] = [:]

    public init(
        supplement: PricingSupplement,
        primary: PricingCatalog,
        secondary: PricingCatalog)
    {
        self.supplement = supplement
        self.primary = primary
        self.secondary = secondary
    }

    public static func bundled(
        supplementData: Data,
        primaryData: Data,
        secondaryData: Data
    ) throws -> ModelPricing {
        ModelPricing(
            supplement: try PricingDecoder.supplement(supplementData),
            primary: try PricingDecoder.compact(primaryData),
            secondary: try PricingDecoder.compact(secondaryData))
    }

    public func resolve(model: String) -> ModelRates? {
        self.lock.lock()
        defer { self.lock.unlock() }
        if let cached = self.memo[model] {
            return cached
        }
        let canonical = self.supplement.canonicalName(for: model) ?? model
        var result = self.supplement.pricing[canonical]
            ?? self.supplement.pricing[model]
            ?? self.primary.lookup(canonical)
            ?? self.secondary.lookup(canonical)
        if var rates = result {
            let lower = model.lowercased()
            if let pair = self.supplement.fastMultipliers.first(where: {
                lower.contains($0.key.lowercased())
            }) {
                rates.fastMultiplier = pair.value
            }
            result = rates
        }
        self.memo[model] = result
        return result
    }

    public func estimatedCostDollars(
        model: String,
        tokens: TokenBreakdown,
        applyLongContextRates: Bool = true
    ) -> Double? {
        self.resolve(model: model)?.costDollars(
            for: tokens,
            applyLongContextRates: applyLongContextRates)
    }
}

public enum PricingResourceError: Error, Equatable {
    case missing(String)
    case invalid
}

private enum PricingDecoder {
    struct Compact: Decodable {
        let retrievedAt: String?
        let models: [String: CompactRate]

        enum CodingKeys: String, CodingKey {
            case retrievedAt = "retrieved_at"
            case models
        }
    }

    struct CompactRate: Decodable {
        let i: Double
        let o: Double
        let cw: Double
        let cr: Double
        let ia: Double?
        let oa: Double?
        let cwa: Double?
        let cra: Double?
        let cre: Bool?
        let fast: Double?
    }

    struct SupplementFile: Decodable {
        let updatedAt: String?
        let pricing: [String: SupplementRate]
        let fastMultipliers: [String: Double]?
        let aliasRules: [Rule]

        enum CodingKeys: String, CodingKey {
            case updatedAt = "updated_at"
            case pricing
            case fastMultipliers = "fast_multipliers"
            case aliasRules = "alias_rules"
        }
    }

    struct SupplementRate: Decodable {
        let input: Double
        let output: Double
        let cacheWrite: Double?
        let cacheRead: Double?

        enum CodingKeys: String, CodingKey {
            case input = "input_per_million"
            case output = "output_per_million"
            case cacheWrite = "cache_write_per_million"
            case cacheRead = "cache_read_per_million"
        }
    }

    struct Rule: Decodable {
        let pattern: String
        let canonical: String
    }

    static func compact(_ data: Data) throws -> PricingCatalog {
        let decoded = try JSONDecoder().decode(Compact.self, from: data)
        return PricingCatalog(
            entries: decoded.models.mapValues { value in
                ModelRates(
                    inputPerMillion: value.i,
                    outputPerMillion: value.o,
                    cacheWritePerMillion: value.cw,
                    cacheReadPerMillion: value.cr,
                    inputAbove200kPerMillion: value.ia,
                    outputAbove200kPerMillion: value.oa,
                    cacheWriteAbove200kPerMillion: value.cwa,
                    cacheReadAbove200kPerMillion: value.cra,
                    cacheReadIsExplicit: value.cre ?? true,
                    fastMultiplier: value.fast ?? 1)
            },
            retrievedAt: decoded.retrievedAt)
    }

    static func supplement(_ data: Data) throws -> PricingSupplement {
        let decoded = try JSONDecoder().decode(SupplementFile.self, from: data)
        return PricingSupplement(
            pricing: decoded.pricing.mapValues { value in
                ModelRates(
                    inputPerMillion: value.input,
                    outputPerMillion: value.output,
                    cacheWritePerMillion: value.cacheWrite ?? value.input,
                    cacheReadPerMillion: value.cacheRead ?? value.input * 0.1,
                    cacheReadIsExplicit: value.cacheRead != nil)
            },
            fastMultipliers: decoded.fastMultipliers ?? [:],
            aliasRules: decoded.aliasRules.compactMap {
                try? PricingSupplement.AliasRule(
                    pattern: $0.pattern,
                    canonical: $0.canonical)
            },
            updatedAt: decoded.updatedAt)
    }
}
