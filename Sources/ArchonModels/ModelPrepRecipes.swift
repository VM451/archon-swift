import Foundation
import ArchonCore

/// A developer-side preparation recipe that maps raw source weights to a
/// directly runnable Archon runtime representation.
///
/// Recipes are data plus documentation only. They never make a raw artifact
/// runnable: `ModelCompatibilityAnalyzer`, `ModelArtifactInspector.isRunnable`,
/// and `MLXModelCatalog` keep rejecting GGUF, SafeTensors, Transformers, and
/// unknown formats until a conversion tool emits a validated manifest.
public struct ModelPrepRecipe: Codable, Sendable, Equatable, Hashable {
    /// Raw source formats this recipe converts from. Always non-empty and
    /// always conversion-required; runnable formats never appear here.
    public let sourceFormats: Set<ArchonModelFormat>
    /// The directly runnable target runtime the converted artifact declares.
    public let targetRuntime: ArchonModelRuntime
    /// The model family this recipe is tuned for, or nil for a
    /// family-neutral recipe.
    public let family: String?
    /// Ordered developer-side preparation steps.
    public let steps: [String]
    /// External developer tooling the steps require. None is bundled with the
    /// runtime package.
    public let tooling: [String]
    /// True when following the recipe ends with an artifact that validates
    /// through `ModelManifestValidator`.
    public let validatesToManifest: Bool

    public init(
        sourceFormats: Set<ArchonModelFormat>,
        targetRuntime: ArchonModelRuntime,
        family: String? = nil,
        steps: [String],
        tooling: [String],
        validatesToManifest: Bool = true
    ) {
        self.sourceFormats = sourceFormats
        self.targetRuntime = targetRuntime
        self.family = family
        self.steps = steps
        self.tooling = tooling
        self.validatesToManifest = validatesToManifest
    }

    /// Fail-closed structural check. Raw-only sources, a directly runnable
    /// target runtime, non-empty steps/tooling, and a bounded family label.
    public var isValid: Bool { validationErrors.isEmpty }

    public var validationErrors: [String] {
        var errors: [String] = []
        if sourceFormats.isEmpty {
            errors.append("sourceFormats must contain at least one raw source format.")
        }
        for format in sourceFormats.sorted(by: { $0.rawValue < $1.rawValue }) where !format.requiresConversion {
            errors.append("\(format.rawValue) is directly runnable and must not appear in a preparation recipe.")
        }
        if targetRuntime != .mlx && targetRuntime != .coreAI {
            errors.append("targetRuntime must be mlx or coreAI.")
        }
        if steps.isEmpty || steps.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            errors.append("steps must be non-empty and contain no blank entries.")
        }
        if tooling.isEmpty || tooling.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            errors.append("tooling must be non-empty and contain no blank entries.")
        }
        if let family {
            let trimmed = family.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.count > 64 {
                errors.append("family must be 1...64 visible characters when present.")
            }
        }
        if !validatesToManifest {
            errors.append("validatesToManifest must be true: recipes end at a validated manifest.")
        }
        return errors
    }
}

/// Fail-closed index of conversion recipes from raw weights to runnable
/// runtime representations.
///
/// Lookup rules:
/// - `family == nil` returns the family-neutral recipe for the pair.
/// - A known family returns the family-tuned recipe for the pair.
/// - An unknown or blank family returns nil instead of guessing guidance.
/// - Runnable sources and non-local targets always return nil.
public enum ModelPrepRecipeIndex {
    /// Families with tuned recipe variants. Matching is case-insensitive.
    public static let knownFamilies: Set<String> = [
        "bert", "deepseek", "falcon", "gemma", "granite", "llama",
        "mistral", "parakeet", "phi", "qwen", "t5", "whisper"
    ]

    /// All family-neutral recipes shipped by the index.
    public static var neutralRecipes: [ModelPrepRecipe] { neutralRecipesByKey.values.sorted {
        ($0.targetRuntime.rawValue, $0.sourceFormats.map(\.rawValue).sorted().joined())
            < ($1.targetRuntime.rawValue, $1.sourceFormats.map(\.rawValue).sorted().joined())
    } }

    public static func recipe(
        source: ArchonModelFormat,
        target: ArchonModelRuntime,
        family: String? = nil
    ) -> ModelPrepRecipe? {
        guard source.requiresConversion else { return nil }
        guard target == .mlx || target == .coreAI else { return nil }
        guard let neutral = neutralRecipesByKey[Key(source: source, target: target)] else { return nil }
        guard let family, !family.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return neutral
        }
        let normalized = family.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard knownFamilies.contains(normalized) else { return nil }
        let display = family.trimmingCharacters(in: .whitespacesAndNewlines)
        return ModelPrepRecipe(
            sourceFormats: neutral.sourceFormats,
            targetRuntime: neutral.targetRuntime,
            family: display,
            steps: [familyPrelude(family: display, source: source, target: target)] + neutral.steps,
            tooling: neutral.tooling,
            validatesToManifest: neutral.validatesToManifest
        )
    }

    private struct Key: Hashable {
        let source: ArchonModelFormat
        let target: ArchonModelRuntime
    }

    private static func familyPrelude(
        family: String,
        source: ArchonModelFormat,
        target: ArchonModelRuntime
    ) -> String {
        "Confirm the \(source.rawValue) checkpoint is a genuine \(family)-family release from its first-party publisher; community requantizations need their own tokenizer and config review before converting to \(target.rawValue)."
    }

    private static let neutralRecipesByKey: [Key: ModelPrepRecipe] = {
        var recipes: [Key: ModelPrepRecipe] = [:]

        recipes[Key(source: .gguf, target: .mlx)] = ModelPrepRecipe(
            sourceFormats: [.gguf],
            targetRuntime: .mlx,
            steps: [
                "On a developer Mac, obtain the original (non-GGUF) Hugging Face checkpoint for the same model release; GGUF is a quantized export and cannot be mechanically reversed into MLX weights.",
                "Convert the original checkpoint with mlx-lm (`mlx_lm.convert --hf-path <repo> -q`) on the developer machine.",
                "Validate the converted directory with `archon-model validate` against the generated manifest.",
                "Package the validated directory with `archon-model package`, then import the package into the app's model library."
            ],
            tooling: ["mlx-lm", "archon-model"]
        )
        recipes[Key(source: .gguf, target: .coreAI)] = ModelPrepRecipe(
            sourceFormats: [.gguf],
            targetRuntime: .coreAI,
            steps: [
                "On a developer Mac, obtain the original (non-GGUF) Hugging Face checkpoint for the same model release.",
                "Export the checkpoint with Apple's Core AI tooling (`uv run coreai.llm.export <model> --platform <macOS|iOS>`) from an apple/coreai-models checkout, or reuse `archon-model convert`.",
                "Validate the exported .aimodel bundle with `archon-model validate`.",
                "Import the validated bundle into the app's model library."
            ],
            tooling: ["apple/coreai-models", "uv", "archon-model"]
        )
        recipes[Key(source: .safetensors, target: .mlx)] = ModelPrepRecipe(
            sourceFormats: [.safetensors],
            targetRuntime: .mlx,
            steps: [
                "On a developer Mac, fetch the full Hugging Face repository (weights, config.json, tokenizer files) for the SafeTensors checkpoint.",
                "Convert the repository with mlx-lm (`mlx_lm.convert --hf-path <repo> -q`).",
                "Validate the converted directory with `archon-model validate`.",
                "Package the validated directory with `archon-model package`, then import the package."
            ],
            tooling: ["mlx-lm", "archon-model"]
        )
        recipes[Key(source: .safetensors, target: .coreAI)] = ModelPrepRecipe(
            sourceFormats: [.safetensors],
            targetRuntime: .coreAI,
            steps: [
                "On a developer Mac, fetch the full Hugging Face repository for the SafeTensors checkpoint.",
                "Check whether apple/coreai-models ships a registry preset for the model; without one, use the experimental export path and keep the result marked Experimental.",
                "Export with Apple's Core AI tooling or `archon-model convert`, then validate with `archon-model validate`.",
                "Import the validated .aimodel bundle into the app's model library."
            ],
            tooling: ["apple/coreai-models", "uv", "archon-model"]
        )
        recipes[Key(source: .transformers, target: .mlx)] = ModelPrepRecipe(
            sourceFormats: [.transformers],
            targetRuntime: .mlx,
            steps: [
                "On a developer Mac, fetch the full Transformers repository (config.json, tokenizer files, and weight shards).",
                "Convert the repository with mlx-lm (`mlx_lm.convert --hf-path <repo> -q`).",
                "Validate the converted directory with `archon-model validate`.",
                "Package the validated directory with `archon-model package`, then import the package."
            ],
            tooling: ["mlx-lm", "archon-model"]
        )
        recipes[Key(source: .transformers, target: .coreAI)] = ModelPrepRecipe(
            sourceFormats: [.transformers],
            targetRuntime: .coreAI,
            steps: [
                "On a developer Mac, fetch the full Transformers repository for the checkpoint.",
                "Check whether apple/coreai-models ships a registry preset for the model; without one, use the experimental export path and keep the result marked Experimental.",
                "Export with Apple's Core AI tooling or `archon-model convert`, then validate with `archon-model validate`.",
                "Import the validated .aimodel bundle into the app's model library."
            ],
            tooling: ["apple/coreai-models", "uv", "archon-model"]
        )
        return recipes
    }()
}
