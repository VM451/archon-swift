import Foundation
import ArchonCore
import ArchonModels

public enum ModelPrivacyPolicy: String, Codable, CaseIterable, Sendable {
    case localOnly
    case preferLocal
    case appleOnly
    case customLocalOnly
    case cloudAllowed
}

public struct ModelPolicy: Codable, Equatable, Sendable {
    public let privacy: ModelPrivacyPolicy
    public let capability: ArchonModelTask
    public let preferredRuntime: ArchonModelRuntime?

    public init(
        privacy: ModelPrivacyPolicy = .preferLocal,
        capability: ArchonModelTask = .textGeneration,
        preferredRuntime: ArchonModelRuntime? = nil
    ) {
        self.privacy = privacy
        self.capability = capability
        self.preferredRuntime = preferredRuntime
    }
}

public enum AgentModelSelection: Equatable, Sendable {
    case appleFoundationModel
    case installed(ModelVariant)
    case downloadRequired(ModelVariant)
    case unavailable(String)
}

/// Selects a model from deterministic capability metadata. It never asks an LLM to
/// estimate memory fit and it never routes a local-only policy to a cloud model.
public enum AgentModelRouter {
    public static func select(
        policy: ModelPolicy,
        device: ArchonDeviceCapabilities,
        installed: [InstalledModel] = [],
        candidates: [ModelDescriptor] = []
    ) -> AgentModelSelection {
        if policy.privacy == .appleOnly {
            guard policy.preferredRuntime == nil || policy.preferredRuntime == .foundationModels else {
                return .unavailable("The appleOnly policy cannot use a non-Apple Foundation Model runtime.")
            }
            guard policy.capability == .textGeneration else {
                return .unavailable("Apple Foundation Models are only selected here for text generation; the requested capability requires another runtime.")
            }
            return device.supportsAppleFoundationModels
                ? .appleFoundationModel
                : .unavailable("Apple Foundation Models are unavailable on this device.")
        }
        if (policy.privacy == .localOnly || policy.privacy == .preferLocal) &&
            device.supportsAppleFoundationModels &&
            policy.preferredRuntime == nil &&
            policy.capability == .textGeneration {
            return .appleFoundationModel
        }

        let installedVariants = installed.compactMap { model -> ModelVariant? in
            guard model.manifest.capabilities.tasks.contains(policy.capability) else { return nil }
            return ModelVariant(
                id: model.id,
                name: model.manifest.modelName,
                modelID: model.manifest.modelID,
                source: .localImport,
                format: model.manifest.format,
                runtime: model.manifest.runtime,
                architecture: model.manifest.architecture,
                supportedDeviceArchitectures: model.manifest.supportedDeviceArchitectures,
                supportedPlatforms: model.manifest.platforms,
                minimumOS: model.manifest.minimumOS,
                contextLength: model.manifest.contextLength,
                precision: model.manifest.precision,
                quantization: model.manifest.quantization,
                kvCacheBytesPerToken: model.manifest.kvCacheBytesPerToken,
                sizeBytes: model.manifest.modelSizeBytes,
                estimatedMemoryBytes: model.manifest.estimatedMemoryBytes,
                estimatedQualityScore: model.manifest.estimatedQualityScore,
                estimatedTokensPerSecond: model.manifest.estimatedTokensPerSecond,
                sha256: model.manifest.checksum,
                resources: model.manifest.modelResources,
                tokenizerResources: model.manifest.tokenizerResources,
                capabilities: model.manifest.capabilities,
                isExperimental: model.manifest.isExperimental
            )
        }

        if let selected = bestVariant(from: installedVariants, policy: policy, device: device) {
            return .installed(selected)
        }

        if let selected = bestVariant(from: candidates.flatMap(\.variants), policy: policy, device: device) {
            return .downloadRequired(selected)
        }

        if policy.privacy == .cloudAllowed || policy.privacy == .preferLocal {
            return .unavailable("No compatible local model is installed or catalogued; a remote provider may be selected by the host application.")
        }
        return .unavailable("No compatible local model satisfies the requested policy.")
    }

    private static func bestVariant(
        from variants: [ModelVariant],
        policy: ModelPolicy,
        device: ArchonDeviceCapabilities
    ) -> ModelVariant? {
        variants
            .filter { policy.preferredRuntime == nil || $0.runtime == policy.preferredRuntime }
            .filter { $0.capabilities.tasks.contains(policy.capability) }
            .filter { variant in
                switch policy.privacy {
                case .localOnly, .customLocalOnly:
                    return variant.runtime == .coreAI || variant.runtime == .mlx
                default:
                    return true
                }
            }
            .filter { ModelCompatibilityAnalyzer.analyze(variant: $0, device: device).canLoad }
            .sorted { lhs, rhs in
                let lhsFit = ModelCompatibilityAnalyzer.analyze(variant: lhs, device: device).fit
                let rhsFit = ModelCompatibilityAnalyzer.analyze(variant: rhs, device: device).fit
                let leftFitRank = fitRank(lhsFit)
                let rightFitRank = fitRank(rhsFit)
                if leftFitRank != rightFitRank { return leftFitRank < rightFitRank }
                let leftQuality = normalizedQuality(lhs.estimatedQualityScore)
                let rightQuality = normalizedQuality(rhs.estimatedQualityScore)
                if leftQuality != rightQuality { return leftQuality > rightQuality }
                let leftSpeed = normalizedSpeed(lhs.estimatedTokensPerSecond)
                let rightSpeed = normalizedSpeed(rhs.estimatedTokensPerSecond)
                if leftSpeed != rightSpeed { return leftSpeed > rightSpeed }
                let leftRuntimeRank = runtimeRank(lhs.runtime)
                let rightRuntimeRank = runtimeRank(rhs.runtime)
                if leftRuntimeRank != rightRuntimeRank { return leftRuntimeRank < rightRuntimeRank }
                return (lhs.sizeBytes ?? Int64.max, lhs.id) < (rhs.sizeBytes ?? Int64.max, rhs.id)
            }
            .first
    }

    private static func fitRank(_ fit: ModelFitRating) -> Int {
        switch fit {
        case .excellentFit: 0
        case .goodFit: 1
        case .mayBeSlow: 2
        case .memoryConstrained: 3
        case .notRecommended: 4
        case .cannotRun: 5
        }
    }

    private static func runtimeRank(_ runtime: ArchonModelRuntime) -> Int {
        switch runtime {
        case .coreAI: 0
        case .mlx: 1
        case .foundationModels: 2
        case .remote: 3
        case .unknown: 4
        }
    }

    private static func normalizedQuality(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    private static func normalizedSpeed(_ value: Double?) -> Double {
        guard let value, value.isFinite, value >= 0 else { return 0 }
        return value
    }
}
