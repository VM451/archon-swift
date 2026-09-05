import Foundation

/// User optimization preference for balancing speed, intelligence, and RAM footprint.
public enum OnDeviceOptimizationPreference: String, Codable, Equatable, Sendable {
    /// Automatically balances speed, reasoning intelligence, and RAM headroom according to device tier.
    case adaptive

    /// Prioritizes fast token generation speed and minimal memory footprint.
    case speedFirst

    /// Balances moderate reasoning capability and safe memory margins.
    case balanced

    /// Prioritizes higher reasoning intelligence and larger context windows within the device's RAM limits.
    case intelligenceFirst
}

/// Specifications for a curated Gemma 4 model variant compatible with MLX Swift and Apple Core AI.
public struct GemmaVariant: Sendable, Equatable, Codable {
    /// A human-readable identifier for this variant.
    public let name: String

    /// The Hugging Face model repository identifier.
    public let huggingFaceID: String

    /// Apple Core AI model identifier or compiled asset name.
    public let coreAIModelIdentifier: String

    /// Repository branch or revision pin.
    public let revision: String

    /// Approximate parameter count label (e.g. "E2B", "E4B", "4B", "9B", "26B-A4B").
    public let parameterCount: String

    /// Quantization format (e.g. "4-bit", "8-bit", "4-bit QAT").
    public let quantization: String

    /// Estimated runtime memory usage during inference in megabytes.
    public let estimatedMemoryMB: Int

    /// Minimum recommended physical system RAM in gigabytes.
    public let minSystemRAMGB: Double

    /// Maximum context window in tokens.
    public let maxContextTokens: Int

    /// Any special extra end-of-sequence tokens required by this model's tokenizer.
    public let extraEOSTokens: [String]

    public init(
        name: String,
        huggingFaceID: String,
        coreAIModelIdentifier: String? = nil,
        revision: String = "main",
        parameterCount: String,
        quantization: String = "4-bit",
        estimatedMemoryMB: Int,
        minSystemRAMGB: Double,
        maxContextTokens: Int = 8192,
        extraEOSTokens: [String] = ["<end_of_turn>"]
    ) {
        self.name = name
        self.huggingFaceID = huggingFaceID
        self.coreAIModelIdentifier = coreAIModelIdentifier ?? "\(huggingFaceID.replacingOccurrences(of: "/", with: ".")).coreai"
        self.revision = revision
        self.parameterCount = parameterCount
        self.quantization = quantization
        self.estimatedMemoryMB = estimatedMemoryMB
        self.minSystemRAMGB = minSystemRAMGB
        self.maxContextTokens = maxContextTokens
        self.extraEOSTokens = extraEOSTokens
    }

    /// Converts this Gemma variant to an `MLXModelSource`.
    public var asModelSource: MLXModelSource {
        .huggingFace(id: huggingFaceID, revision: revision)
    }

    /// Converts this Gemma variant to a `CoreAIModelSource`.
    public var asCoreAISource: CoreAIModelSource {
        .modelIdentifier(coreAIModelIdentifier)
    }
}

/// Curated catalog of Google Gemma 4 model variants with hardware-adaptive sizing.
public enum GemmaModelCatalog: Sendable {
    // MARK: - Curated Gemma 4 Variants

    /// Gemma 4 E2B 4-bit: Compact, highly-efficient edge variant with low latency.
    /// Ideal for UltraLight tier (< 5 GB RAM: iPhone 11/12/13/14 base, entry iPads) and speed-first mode.
    public static let gemma4_e2b_4bit = GemmaVariant(
        name: "Gemma 4 E2B 4-bit",
        huggingFaceID: "mlx-community/gemma-4-e2b-it-4bit",
        coreAIModelIdentifier: "gemma-4-e2b-it-4bit.coreai",
        parameterCount: "E2B",
        quantization: "4-bit",
        estimatedMemoryMB: 1450,
        minSystemRAMGB: 3.5,
        maxContextTokens: 8192,
        extraEOSTokens: ["<end_of_turn>"]
    )

    /// Gemma 4 E4B 4-bit: Efficient 4-parameter edge model.
    /// Ideal for Balanced tier (5GB – 7.9GB RAM: iPhone 13 Pro, 14 Pro, 15 base).
    public static let gemma4_e4b_4bit = GemmaVariant(
        name: "Gemma 4 E4B 4-bit",
        huggingFaceID: "mlx-community/gemma-4-e4b-it-4bit",
        coreAIModelIdentifier: "gemma-4-e4b-it-4bit.coreai",
        parameterCount: "E4B",
        quantization: "4-bit",
        estimatedMemoryMB: 2600,
        minSystemRAMGB: 5.5,
        maxContextTokens: 8192,
        extraEOSTokens: ["<end_of_turn>"]
    )

    /// Gemma 4 4B 4-bit: Advanced 4-parameter reasoning variant.
    public static let gemma4_4b_4bit = GemmaVariant(
        name: "Gemma 4 4B 4-bit",
        huggingFaceID: "mlx-community/gemma-4-4b-it-4bit",
        coreAIModelIdentifier: "gemma-4-4b-it-4bit.coreai",
        parameterCount: "4B",
        quantization: "4-bit",
        estimatedMemoryMB: 2750,
        minSystemRAMGB: 5.5,
        maxContextTokens: 8192,
        extraEOSTokens: ["<end_of_turn>"]
    )

    /// Gemma 4 9B 4-bit: High-intelligence reasoning powerhouse with expanded context window.
    /// Ideal for Performance tier (>= 8GB RAM: M-series Macs, iPads with 8GB+ RAM, Intel Macs).
    public static let gemma4_9b_4bit = GemmaVariant(
        name: "Gemma 4 9B 4-bit",
        huggingFaceID: "mlx-community/gemma-4-9b-it-4bit",
        coreAIModelIdentifier: "gemma-4-9b-it-4bit.coreai",
        parameterCount: "9B",
        quantization: "4-bit",
        estimatedMemoryMB: 5800,
        minSystemRAMGB: 8.0,
        maxContextTokens: 16384,
        extraEOSTokens: ["<end_of_turn>"]
    )

    /// Gemma 4 26B-A4B 4-bit: Mixture-of-Experts (MoE) variant with 4B active parameters.
    public static let gemma4_26b_a4b_4bit = GemmaVariant(
        name: "Gemma 4 26B-A4B 4-bit",
        huggingFaceID: "mlx-community/gemma-4-26b-a4b-it-4bit",
        coreAIModelIdentifier: "gemma-4-26b-a4b-it-4bit.coreai",
        parameterCount: "26B-A4B",
        quantization: "4-bit",
        estimatedMemoryMB: 6200,
        minSystemRAMGB: 8.0,
        maxContextTokens: 16384,
        extraEOSTokens: ["<end_of_turn>"]
    )

    /// Default Gemma 4 variant across the system.
    public static let defaultVariant = gemma4_e2b_4bit

    /// All currently bundled Gemma entries. The adaptive resolver consumes
    /// these through `AdaptiveModelCatalog`; this list remains available for
    /// source compatibility and explicit Gemma-only selection.
    public static let allVariants: [GemmaVariant] = [
        gemma4_e2b_4bit,
        gemma4_e4b_4bit,
        gemma4_4b_4bit,
        gemma4_9b_4bit,
        gemma4_26b_a4b_4bit
    ]

    // MARK: - Sizing Engine & Model Resolution

    /// Resolves the optimal Gemma 4 model variant strictly respecting the 50% process memory headroom rule.
    ///
    /// - Parameters:
    ///   - profile: The hardware profile containing process limits and safe model budget.
    ///   - preference: The optimization preference (adaptive, speedFirst, balanced, intelligenceFirst).
    /// - Returns: The curated `GemmaVariant` matching the requirements.
    public static func resolve(
        for profile: DeviceHardwareProfile,
        preference: OnDeviceOptimizationPreference = .adaptive
    ) -> GemmaVariant {
        let budgetMB = profile.safeModelMemoryBudgetMB

        // If the 50% model budget is constrained (< 2000 MB), choose lightweight E2B to guarantee host app headroom
        if budgetMB < 2000 {
            switch preference {
            case .speedFirst, .adaptive, .balanced:
                return gemma4_e2b_4bit
            case .intelligenceFirst:
                // If the device has close to 2GB budget, allow E4B if preferred
                return budgetMB >= 1400 ? gemma4_e4b_4bit : gemma4_e2b_4bit
            }
        }

        // Moderate budget (2000 MB – 3999 MB)
        if budgetMB < 4000 {
            switch preference {
            case .speedFirst:
                return gemma4_e2b_4bit
            case .adaptive, .balanced:
                return gemma4_e4b_4bit
            case .intelligenceFirst:
                return gemma4_4b_4bit
            }
        }

        // Generous budget (>= 4000 MB: macOS, 16GB+ devices)
        switch preference {
        case .speedFirst:
            return gemma4_e2b_4bit
        case .balanced:
            return gemma4_4b_4bit
        case .adaptive, .intelligenceFirst:
            return gemma4_9b_4bit
        }
    }

    /// Resolves the optimal Gemma 4 model variant by hardware memory tier.
    ///
    /// - Parameters:
    ///   - memoryTier: The physical RAM tier of the target device.
    ///   - preference: The optimization preference.
    /// - Returns: The curated `GemmaVariant`.
    public static func resolve(
        for memoryTier: HardwareMemoryTier,
        preference: OnDeviceOptimizationPreference = .adaptive
    ) -> GemmaVariant {
        switch (memoryTier, preference) {
        // MARK: Ultra-Light Hardware (< 5GB RAM: iPhone 11, 12, 13 base, entry iPads)
        case (.ultraLight, .speedFirst),
             (.ultraLight, .adaptive),
             (.ultraLight, .balanced):
            return gemma4_e2b_4bit

        case (.ultraLight, .intelligenceFirst):
            return gemma4_e4b_4bit

        // MARK: Balanced Hardware (5GB – 7.9GB RAM: iPhone 13 Pro, 14 Pro, 15 base)
        case (.balanced, .speedFirst):
            return gemma4_e2b_4bit

        case (.balanced, .adaptive),
             (.balanced, .balanced):
            return gemma4_e4b_4bit

        case (.balanced, .intelligenceFirst):
            return gemma4_4b_4bit

        // MARK: Performance Hardware (>= 8GB RAM: M-series Macs, iPads, 8GB+ iPhones, Intel Macs)
        case (.performance, .speedFirst):
            return gemma4_e2b_4bit

        case (.performance, .balanced):
            return gemma4_4b_4bit

        case (.performance, .adaptive),
             (.performance, .intelligenceFirst):
            return gemma4_9b_4bit
        }
    }
}
