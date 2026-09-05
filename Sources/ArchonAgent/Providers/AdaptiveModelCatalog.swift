import Foundation
import ArchonCore
import ArchonModels

/// A concrete local runtime source that can participate in adaptive selection.
///
/// The catalog is intentionally source-oriented rather than family-oriented:
/// a new MLX or Core AI model can be added without introducing another model
/// family enum or changing `OnDeviceProvider`.
public enum AdaptiveModelSource: Sendable, Equatable {
    case mlx(source: MLXModelSource, extraEOSTokens: Set<String>)
    case coreAI(source: CoreAIModelSource, computeUnit: CoreAIComputeUnit)
}

public enum AdaptiveModelSelectionError: Error, LocalizedError, Sendable, Equatable {
    case noCompatibleCandidate

    public var errorDescription: String? {
        switch self {
        case .noCompatibleCandidate:
            return "No catalogued local model satisfies the device, runtime, and context requirements."
        }
    }
}

/// Fail-closed provider used when an adaptive catalog has no eligible entry.
/// It prevents an unsupported model from being silently substituted.
struct UnavailableAdaptiveModelProvider: LLMProvider, Sendable {
    let id = "ondevice.unavailable"
    let capabilities = ModelCapabilities(isOnDevice: true)

    func generate(
        prompt: [ChatMessage],
        tools: [ToolDefinition],
        options: GenerationOptions
    ) async throws -> ModelResponse {
        throw AdaptiveModelSelectionError.noCompatibleCandidate
    }

    func stream(
        prompt: [ChatMessage],
        tools: [ToolDefinition],
        options: GenerationOptions
    ) -> AsyncThrowingStream<ModelResponseChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: AdaptiveModelSelectionError.noCompatibleCandidate)
        }
    }
}

/// A catalog entry used by hardware-aware local model selection.
///
/// Scores are optional catalog metadata. Archon never invents benchmark
/// results: when a score is absent, selection falls back to deterministic fit,
/// memory, and stable identifier ordering.
public struct AdaptiveModelCandidate: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let family: String?
    public let source: AdaptiveModelSource
    public let capabilities: ModelCapabilities
    public let estimatedMemoryBytes: UInt64?
    public let modelSizeBytes: Int64?
    public let maxContextTokens: Int
    public let minimumSystemRAMGB: Double?
    public let estimatedQualityScore: Double?
    public let estimatedTokensPerSecond: Double?
    public let estimatedPromptTokensPerSecond: Double?
    public let estimatedEnergyEfficiencyScore: Double?
    public let estimatedThermalScore: Double?
    public let supportedPlatforms: Set<ApplePlatformKind>
    public let licenseIdentifier: String?
    let legacyGemmaVariant: GemmaVariant?

    public init(
        id: String,
        name: String,
        family: String? = nil,
        source: AdaptiveModelSource,
        capabilities: ModelCapabilities = .mlxLocal,
        estimatedMemoryBytes: UInt64? = nil,
        modelSizeBytes: Int64? = nil,
        maxContextTokens: Int = 8_192,
        minimumSystemRAMGB: Double? = nil,
        estimatedQualityScore: Double? = nil,
        estimatedTokensPerSecond: Double? = nil,
        estimatedPromptTokensPerSecond: Double? = nil,
        estimatedEnergyEfficiencyScore: Double? = nil,
        estimatedThermalScore: Double? = nil,
        supportedPlatforms: Set<ApplePlatformKind> = Set(ApplePlatformKind.allCases),
        licenseIdentifier: String? = nil
    ) {
        self.init(
            id: id,
            name: name,
            family: family,
            source: source,
            capabilities: capabilities,
            estimatedMemoryBytes: estimatedMemoryBytes,
            modelSizeBytes: modelSizeBytes,
            maxContextTokens: maxContextTokens,
            minimumSystemRAMGB: minimumSystemRAMGB,
            estimatedQualityScore: estimatedQualityScore,
            estimatedTokensPerSecond: estimatedTokensPerSecond,
            estimatedPromptTokensPerSecond: estimatedPromptTokensPerSecond,
            estimatedEnergyEfficiencyScore: estimatedEnergyEfficiencyScore,
            estimatedThermalScore: estimatedThermalScore,
            supportedPlatforms: supportedPlatforms,
            licenseIdentifier: licenseIdentifier,
            legacyGemmaVariant: nil
        )
    }

    init(
        id: String,
        name: String,
        family: String? = nil,
        source: AdaptiveModelSource,
        capabilities: ModelCapabilities = .mlxLocal,
        estimatedMemoryBytes: UInt64? = nil,
        modelSizeBytes: Int64? = nil,
        maxContextTokens: Int = 8_192,
        minimumSystemRAMGB: Double? = nil,
        estimatedQualityScore: Double? = nil,
        estimatedTokensPerSecond: Double? = nil,
        estimatedPromptTokensPerSecond: Double? = nil,
        estimatedEnergyEfficiencyScore: Double? = nil,
        estimatedThermalScore: Double? = nil,
        supportedPlatforms: Set<ApplePlatformKind> = Set(ApplePlatformKind.allCases),
        licenseIdentifier: String? = nil,
        legacyGemmaVariant: GemmaVariant?
    ) {
        self.id = id
        self.name = name
        self.family = family
        self.source = source
        self.capabilities = capabilities
        self.estimatedMemoryBytes = estimatedMemoryBytes
        self.modelSizeBytes = modelSizeBytes
        self.maxContextTokens = max(1, maxContextTokens)
        self.minimumSystemRAMGB = minimumSystemRAMGB
        self.estimatedQualityScore = Self.normalizedScore(estimatedQualityScore)
        self.estimatedTokensPerSecond = Self.nonNegative(estimatedTokensPerSecond)
        self.estimatedPromptTokensPerSecond = Self.nonNegative(estimatedPromptTokensPerSecond)
        self.estimatedEnergyEfficiencyScore = Self.normalizedScore(estimatedEnergyEfficiencyScore)
        self.estimatedThermalScore = Self.normalizedScore(estimatedThermalScore)
        self.supportedPlatforms = supportedPlatforms
        self.licenseIdentifier = licenseIdentifier
        self.legacyGemmaVariant = legacyGemmaVariant
    }

    /// Creates a generic candidate from a model descriptor returned by an
    /// Archon catalog. Only local runtimes with a source Archon can resolve are
    /// included; Foundation Models remains the system-model path.
    public init?(
        descriptor: ModelDescriptor,
        variant: ModelVariant,
        extraEOSTokens: Set<String> = []
    ) {
        let source: AdaptiveModelSource
        switch variant.runtime {
        case .mlx:
            guard variant.format == .mlx else { return nil }
            switch variant.source {
            case .huggingFace:
                source = .mlx(
                    source: .huggingFace(id: variant.modelID, revision: descriptor.revision ?? "main"),
                    extraEOSTokens: extraEOSTokens
                )
            case .localImport:
                guard let directory = descriptor.sourceURL else { return nil }
                source = .mlx(source: .localDirectory(directory), extraEOSTokens: extraEOSTokens)
            default:
                return nil
            }
        case .coreAI:
            guard variant.format == .aimodel || variant.format == .coreAIBundle else { return nil }
            source = .coreAI(
                source: .modelIdentifier(variant.modelID),
                computeUnit: .neuralEngineFirst
            )
        case .foundationModels, .remote, .unknown:
            return nil
        }

        let taskCapabilities = variant.capabilities
        let capabilities = ModelCapabilities(
            supportsStreaming: taskCapabilities.supportsStreaming,
            supportsToolCalling: taskCapabilities.supportsToolCalling,
            supportsVision: taskCapabilities.tasks.contains(.vision),
            supportsJSONSchema: taskCapabilities.supportsStructuredOutput,
            maxContextTokens: variant.contextLength ?? 8_192,
            isOnDevice: true
        )
        let memoryBytes = variant.estimatedMemoryBytes.map { UInt64(max(0, $0)) }
            ?? variant.sizeBytes.map { UInt64(max(0, Int64(Double($0) * 1.15))) }
        let platforms = Set(variant.supportedPlatforms.compactMap { platform in
            ApplePlatformKind(rawValue: platform.rawValue)
        })

        self.init(
            id: variant.id,
            name: variant.name,
            family: descriptor.family,
            source: source,
            capabilities: capabilities,
            estimatedMemoryBytes: memoryBytes,
            modelSizeBytes: variant.sizeBytes,
            maxContextTokens: variant.contextLength ?? 8_192,
            estimatedQualityScore: variant.estimatedQualityScore,
            estimatedTokensPerSecond: variant.estimatedTokensPerSecond,
            supportedPlatforms: platforms.isEmpty ? Set(ApplePlatformKind.allCases) : platforms,
            licenseIdentifier: descriptor.license?.identifier
        )
    }

    private static func normalizedScore(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, 0), 1)
    }

    private static func nonNegative(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return max(value, 0)
    }
}

/// A value-type catalog for adaptive local model selection.
///
/// `builtIn` is a small validated seed catalog. Applications can merge model
/// descriptors returned by Hugging Face or an app-owned registry at runtime,
/// so monthly model releases do not require a new model-family implementation
/// or a change to the selection algorithm.
public struct AdaptiveModelCatalog: Sendable, Equatable {
    public let candidates: [AdaptiveModelCandidate]

    public init(candidates: [AdaptiveModelCandidate]) {
        var seen = Set<String>()
        self.candidates = candidates.filter { seen.insert($0.id).inserted }
    }

    /// Builds an adaptive catalog from any model descriptors supplied by the
    /// consuming application or a remote catalog.
    public init(
        descriptors: [ModelDescriptor],
        extraEOSTokensByModelID: [String: Set<String>] = [:]
    ) {
        self.init(candidates: descriptors.flatMap { descriptor in
            descriptor.variants.compactMap { variant in
                AdaptiveModelCandidate(
                    descriptor: descriptor,
                    variant: variant,
                    extraEOSTokens: extraEOSTokensByModelID[descriptor.id] ?? []
                )
            }
        })
    }

    /// Fetches descriptors from any Archon model catalog provider and converts
    /// its directly runnable variants into adaptive candidates. This keeps
    /// monthly catalog refreshes in the consuming app's catalog/update job;
    /// the selector itself remains deterministic and side-effect free.
    public static func load(
        from provider: any ModelCatalogProvider,
        request: ModelSearchRequest = ModelSearchRequest(query: "", includeVariants: true),
        extraEOSTokensByModelID: [String: Set<String>] = [:]
    ) async throws -> AdaptiveModelCatalog {
        let descriptors = try await provider.search(request)
        return AdaptiveModelCatalog(
            descriptors: descriptors,
            extraEOSTokensByModelID: extraEOSTokensByModelID
        )
    }

    /// The current bundled compatibility seed. It is represented through the
    /// generic candidate type; the resolver's Gemma compatibility branch only
    /// preserves the historical default until an app supplies refreshed data.
    public static var builtIn: AdaptiveModelCatalog {
        AdaptiveModelCatalog(
            candidates: GemmaModelCatalog.allVariants.flatMap { variant in
                [
                    AdaptiveModelCandidate(
                        id: "\(variant.huggingFaceID)#mlx",
                        name: variant.name,
                        family: "Gemma",
                        source: .mlx(
                            source: variant.asModelSource,
                            extraEOSTokens: Set(variant.extraEOSTokens)
                        ),
                        capabilities: ModelCapabilities(
                            supportsStreaming: true,
                            supportsToolCalling: true,
                            supportsVision: false,
                            supportsJSONSchema: false,
                            maxContextTokens: variant.maxContextTokens,
                            isOnDevice: true
                        ),
                        estimatedMemoryBytes: UInt64(variant.estimatedMemoryMB) * 1024 * 1024,
                        maxContextTokens: variant.maxContextTokens,
                        minimumSystemRAMGB: variant.minSystemRAMGB,
                        legacyGemmaVariant: variant
                    ),
                    AdaptiveModelCandidate(
                        id: "\(variant.coreAIModelIdentifier)#coreAI",
                        name: variant.name,
                        family: "Gemma",
                        source: .coreAI(
                            source: variant.asCoreAISource,
                            computeUnit: .neuralEngineFirst
                        ),
                        capabilities: ModelCapabilities(
                            supportsStreaming: true,
                            supportsToolCalling: true,
                            supportsVision: false,
                            supportsJSONSchema: true,
                            maxContextTokens: variant.maxContextTokens,
                            isOnDevice: true
                        ),
                        estimatedMemoryBytes: UInt64(variant.estimatedMemoryMB) * 1024 * 1024,
                        maxContextTokens: variant.maxContextTokens,
                        minimumSystemRAMGB: variant.minSystemRAMGB,
                        legacyGemmaVariant: variant
                    )
                ]
            }
        )
    }

    /// Returns a catalog with app- or release-specific candidates appended.
    public func appending(_ additionalCandidates: [AdaptiveModelCandidate]) -> AdaptiveModelCatalog {
        AdaptiveModelCatalog(candidates: candidates + additionalCandidates)
    }

    /// Resolves a candidate using hard device requirements first, then a
    /// deterministic weighted score. Missing benchmark metadata never makes a
    /// candidate more attractive than a measured candidate.
    public func resolve(
        for profile: DeviceHardwareProfile,
        preference: OnDeviceOptimizationPreference = .adaptive,
        runtime: OnDeviceRuntimePreference = .auto,
        minimumContextTokens: Int = 0
    ) -> AdaptiveModelCandidate? {
        let budgetBytes = min(
            profile.safeModelMemoryBudgetBytes,
            profile.availableProcessMemoryBytes
        )
        let eligibleCandidates = candidates.filter { candidate in
            guard candidate.supportedPlatforms.contains(profile.platform) else { return false }
            guard candidate.maxContextTokens >= minimumContextTokens else { return false }
            if let minimumSystemRAMGB = candidate.minimumSystemRAMGB,
               profile.physicalMemoryGB < minimumSystemRAMGB {
                return false
            }
            // Adaptive selection is fail-closed for generic entries: a
            // candidate must publish a peak-memory estimate that fits the
            // current process budget. The legacy Gemma seed retains its
            // established tier policy for source compatibility.
            if candidate.legacyGemmaVariant == nil {
                guard let estimatedMemoryBytes = candidate.estimatedMemoryBytes,
                      estimatedMemoryBytes <= budgetBytes else { return false }
            }
            if case .coreAI = candidate.source, !profile.isCoreAISupported {
                // Keep the historical explicit Gemma preference behavior:
                // callers may construct the Core AI provider and let its
                // runtime/asset boundary report availability. New generic
                // candidates still require a positive Core AI capability
                // declaration before adaptive selection.
                if candidate.legacyGemmaVariant == nil { return false }
            }
            switch runtime {
            case .preferCoreAI:
                guard case .coreAI = candidate.source else { return false }
            case .preferMLX:
                guard case .mlx = candidate.source else { return false }
            case .appleFoundationModelOnly:
                return false
            case .auto:
                break
            }
            return true
        }

        guard !eligibleCandidates.isEmpty else { return nil }

        // `.auto` must not reinterpret a generic MLX weight repository as a
        // Core AI export. If both artifacts are catalogued, keep the existing
        // dynamic MLX default; Core AI remains an explicit preference.
        let runtimeEligible: [AdaptiveModelCandidate]
        if runtime == .auto,
           eligibleCandidates.contains(where: { if case .mlx = $0.source { return true }; return false }) {
            runtimeEligible = eligibleCandidates.filter {
                if case .mlx = $0.source { return true }
                return false
            }
        } else {
            runtimeEligible = eligibleCandidates
        }

        // Preserve the bundled Gemma seed's already-tested hardware policy.
        // This compatibility branch only applies when every eligible entry is
        // a legacy Gemma seed; any supplied monthly catalog entry goes through
        // the generic score below.
        if runtimeEligible.allSatisfy({ $0.legacyGemmaVariant != nil }) {
            let legacyVariant = GemmaModelCatalog.resolve(for: profile, preference: preference)
            if let legacyCandidate = runtimeEligible.first(where: {
                $0.legacyGemmaVariant == legacyVariant
            }) {
                return legacyCandidate
            }
        }

        let eligible = runtimeEligible
        let maximumQuality = eligible.compactMap(\.estimatedQualityScore).max() ?? 1
        let maximumSpeed = eligible.compactMap(\.estimatedTokensPerSecond).max() ?? 1
        let maximumPromptSpeed = eligible.compactMap(\.estimatedPromptTokensPerSecond).max() ?? 1

        return eligible
            .map { candidate in
                (candidate, score(
                    candidate,
                    preference: preference,
                    runtime: runtime,
                    budgetBytes: budgetBytes,
                    maximumQuality: maximumQuality,
                    maximumSpeed: maximumSpeed,
                    maximumPromptSpeed: maximumPromptSpeed
                ))
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.id < rhs.0.id
            }
            .first?.0
    }

    private func score(
        _ candidate: AdaptiveModelCandidate,
        preference: OnDeviceOptimizationPreference,
        runtime: OnDeviceRuntimePreference,
        budgetBytes: UInt64,
        maximumQuality: Double,
        maximumSpeed: Double,
        maximumPromptSpeed: Double
    ) -> Double {
        let memoryFit: Double
        if let estimatedMemoryBytes = candidate.estimatedMemoryBytes {
            let ratio = Double(estimatedMemoryBytes) / Double(max(budgetBytes, 1))
            memoryFit = min(max(1 - ratio, 0), 1)
        } else {
            memoryFit = 0.5
        }
        let quality = candidate.estimatedQualityScore.map { $0 / max(maximumQuality, 0.0001) } ?? 0.5
        let speed = candidate.estimatedTokensPerSecond.map { $0 / max(maximumSpeed, 0.0001) } ?? 0.5
        let promptSpeed = candidate.estimatedPromptTokensPerSecond.map { $0 / max(maximumPromptSpeed, 0.0001) } ?? 0.5
        let energy = candidate.estimatedEnergyEfficiencyScore ?? 0.5
        let thermal = candidate.estimatedThermalScore ?? 0.5
        let compatibility: Double = runtime == .auto ? 1 : 1.0

        let weights: (quality: Double, memory: Double, speed: Double, energy: Double, compatibility: Double)
        switch preference {
        case .speedFirst:
            weights = (0.15, 0.30, 0.25, 0.20, 0.10)
        case .intelligenceFirst:
            weights = (0.40, 0.20, 0.15, 0.10, 0.15)
        case .adaptive, .balanced:
            weights = (0.30, 0.25, 0.20, 0.15, 0.10)
        }

        let contextFit = min(Double(candidate.maxContextTokens) / 16_384, 1)
        let downloadFit = candidate.modelSizeBytes.map { min(1, 1 / max(Double($0) / 1_000_000_000, 1)) } ?? 0.5
        let licenseFit = candidate.licenseIdentifier == nil ? 0.5 : 1.0
        return quality * weights.quality
            + memoryFit * weights.memory
            + (speed * 0.7 + promptSpeed * 0.3) * weights.speed
            + (energy * 0.6 + thermal * 0.4) * weights.energy
            + compatibility * weights.compatibility
            + contextFit * 0.05
            + downloadFit * 0.03
            + licenseFit * 0.02
    }
}
