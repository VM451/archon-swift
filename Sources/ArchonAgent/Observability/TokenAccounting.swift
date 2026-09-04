import Foundation

/// Defines token pricing rates per 1,000,000 (1M) tokens for an LLM model tier.
public struct ModelPricing: Sendable, Codable, Equatable {
    public let modelId: String
    public let inputCostPer1M: Double
    public let outputCostPer1M: Double
    public let cachedInputCostPer1M: Double

    public init(
        modelId: String,
        inputCostPer1M: Double,
        outputCostPer1M: Double,
        cachedInputCostPer1M: Double = 0.0
    ) {
        self.modelId = modelId
        self.inputCostPer1M = inputCostPer1M
        self.outputCostPer1M = outputCostPer1M
        self.cachedInputCostPer1M = cachedInputCostPer1M
    }

    /// Computes total USD cost for a given token usage breakdown.
    public func calculateCost(
        promptTokens: Int,
        completionTokens: Int,
        cachedTokens: Int = 0
    ) -> Double {
        let uncachedPrompt = max(0, promptTokens - cachedTokens)
        let promptCost = (Double(uncachedPrompt) / 1_000_000.0) * inputCostPer1M
        let cachedCost = (Double(cachedTokens) / 1_000_000.0) * cachedInputCostPer1M
        let completionCost = (Double(completionTokens) / 1_000_000.0) * outputCostPer1M
        return promptCost + cachedCost + completionCost
    }

    // MARK: - Pre-configured Model Pricing Tiers

    /// Google Gemini 3.6 Flash / Gemini 2.0 Flash pricing ($0.10 input / $0.40 output per 1M tokens)
    public static let geminiFlash = ModelPricing(
        modelId: "gemini-3.6-flash",
        inputCostPer1M: 0.10,
        outputCostPer1M: 0.40,
        cachedInputCostPer1M: 0.025
    )

    /// Google Gemini 3.6 Pro / Gemini 1.5 Pro pricing ($1.25 input / $5.00 output per 1M tokens)
    public static let geminiPro = ModelPricing(
        modelId: "gemini-3.6-pro",
        inputCostPer1M: 1.25,
        outputCostPer1M: 5.00,
        cachedInputCostPer1M: 0.30
    )

    /// Anthropic Claude 3.5 / 3.7 Sonnet ($3.00 input / $15.00 output per 1M tokens)
    public static let claudeSonnet = ModelPricing(
        modelId: "claude-3-7-sonnet",
        inputCostPer1M: 3.00,
        outputCostPer1M: 15.00,
        cachedInputCostPer1M: 0.30
    )

    /// Anthropic Claude 3.5 Haiku ($0.80 input / $4.00 output per 1M tokens)
    public static let claudeHaiku = ModelPricing(
        modelId: "claude-3-5-haiku",
        inputCostPer1M: 0.80,
        outputCostPer1M: 4.00,
        cachedInputCostPer1M: 0.08
    )

    /// OpenAI GPT-4o ($2.50 input / $10.00 output per 1M tokens)
    public static let gpt4o = ModelPricing(
        modelId: "gpt-4o",
        inputCostPer1M: 2.50,
        outputCostPer1M: 10.00,
        cachedInputCostPer1M: 1.25
    )

    /// OpenAI GPT-4o-mini ($0.15 input / $0.60 output per 1M tokens)
    public static let gpt4oMini = ModelPricing(
        modelId: "gpt-4o-mini",
        inputCostPer1M: 0.15,
        outputCostPer1M: 0.60,
        cachedInputCostPer1M: 0.075
    )

    /// Apple Foundation Models (On-device, $0.00)
    public static let appleFoundation = ModelPricing(
        modelId: "apple-foundation-on-device",
        inputCostPer1M: 0.0,
        outputCostPer1M: 0.0
    )

    /// Local Ollama Models (Self-hosted, $0.00)
    public static let ollamaLocal = ModelPricing(
        modelId: "ollama-local",
        inputCostPer1M: 0.0,
        outputCostPer1M: 0.0
    )

    /// Registry lookup helper for resolving pricing by model name or prefix.
    public static func resolve(for modelId: String) -> ModelPricing {
        let lower = modelId.lowercased()
        if lower.contains("gemini") && (lower.contains("flash") || lower.contains("3.6") || lower.contains("2.0")) {
            return .geminiFlash
        } else if lower.contains("gemini") && lower.contains("pro") {
            return .geminiPro
        } else if lower.contains("claude") && lower.contains("haiku") {
            return .claudeHaiku
        } else if lower.contains("claude") {
            return .claudeSonnet
        } else if lower.contains("gpt-4o-mini") {
            return .gpt4oMini
        } else if lower.contains("gpt-4") || lower.contains("o1") || lower.contains("o3") {
            return .gpt4o
        } else if lower.contains("apple") || lower.contains("afm") {
            return .appleFoundation
        } else if lower.contains("ollama") || lower.contains("llama") || lower.contains("mistral") {
            return .ollamaLocal
        }
        return ModelPricing(modelId: modelId, inputCostPer1M: 0.50, outputCostPer1M: 1.50)
    }
}

/// Token & Cost Calculator for attributing token consumption and costs across runs, nodes, and tools.
public struct CostCalculator: Sendable {
    public init() {}

    /// Calculates token cost for a given provider and usage.
    public static func calculate(usage: TokenUsage, modelId: String, cachedTokens: Int = 0) -> Double {
        let pricing = ModelPricing.resolve(for: modelId)
        return pricing.calculateCost(
            promptTokens: usage.promptTokens,
            completionTokens: usage.completionTokens,
            cachedTokens: cachedTokens
        )
    }
}

/// Detailed breakdown of token usage and costs per provider or execution component.
public struct ProviderCostBreakdown: Sendable, Codable, Equatable, Identifiable {
    public var id: String { providerId }
    public let providerId: String
    public var totalCalls: Int
    public var promptTokens: Int
    public var completionTokens: Int
    public var totalTokens: Int
    public var totalCostUSD: Double

    public init(
        providerId: String,
        totalCalls: Int = 0,
        promptTokens: Int = 0,
        completionTokens: Int = 0,
        totalTokens: Int = 0,
        totalCostUSD: Double = 0.0
    ) {
        self.providerId = providerId
        self.totalCalls = totalCalls
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.totalCostUSD = totalCostUSD
    }

    public mutating func record(usage: TokenUsage, costUSD: Double) {
        self.totalCalls += 1
        self.promptTokens += usage.promptTokens
        self.completionTokens += usage.completionTokens
        self.totalTokens += usage.totalTokens
        self.totalCostUSD += costUSD
    }
}

/// Thread-safe Token Ledger for recording, aggregating, and auditing token consumption and spending.
public actor TokenLedger {
    private var breakdowns: [String: ProviderCostBreakdown] = [:]
    private var nodeUsage: [String: TokenUsage] = [:]
    private var toolUsage: [String: TokenUsage] = [:]

    public init() {}

    /// Records a token-consuming call for a provider.
    public func record(
        providerId: String,
        usage: TokenUsage,
        modelId: String,
        nodeId: String? = nil,
        toolName: String? = nil,
        cachedTokens: Int = 0
    ) -> Double {
        let cost = CostCalculator.calculate(usage: usage, modelId: modelId, cachedTokens: cachedTokens)
        var breakdown = breakdowns[providerId] ?? ProviderCostBreakdown(providerId: providerId)
        breakdown.record(usage: usage, costUSD: cost)
        breakdowns[providerId] = breakdown

        if let node = nodeId {
            let existing = nodeUsage[node] ?? TokenUsage()
            nodeUsage[node] = TokenUsage(
                promptTokens: existing.promptTokens + usage.promptTokens,
                completionTokens: existing.completionTokens + usage.completionTokens,
                totalTokens: existing.totalTokens + usage.totalTokens
            )
        }

        if let tool = toolName {
            let existing = toolUsage[tool] ?? TokenUsage()
            toolUsage[tool] = TokenUsage(
                promptTokens: existing.promptTokens + usage.promptTokens,
                completionTokens: existing.completionTokens + usage.completionTokens,
                totalTokens: existing.totalTokens + usage.totalTokens
            )
        }

        return cost
    }

    /// Fetches the overall aggregated cost across all recorded providers.
    public func totalCostUSD() -> Double {
        breakdowns.values.reduce(0.0) { $0 + $1.totalCostUSD }
    }

    /// Fetches all provider breakdowns.
    public func allBreakdowns() -> [ProviderCostBreakdown] {
        Array(breakdowns.values)
    }

    /// Fetches token usage attributed to a specific node.
    public func usage(forNode nodeId: String) -> TokenUsage {
        nodeUsage[nodeId] ?? TokenUsage()
    }

    /// Fetches token usage attributed to a specific tool.
    public func usage(forTool toolName: String) -> TokenUsage {
        toolUsage[toolName] ?? TokenUsage()
    }

    /// Clears the ledger.
    public func reset() {
        breakdowns.removeAll()
        nodeUsage.removeAll()
        toolUsage.removeAll()
    }
}
