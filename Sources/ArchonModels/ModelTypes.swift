import CryptoKit
import Foundation
import ArchonCore

public enum ArchonModelFormat: String, Codable, CaseIterable, Sendable {
    case aimodel
    case coreAIBundle
    case gguf
    case mlx
    case safetensors
    case transformers
    case unknown

    public var requiresConversion: Bool {
        switch self {
        case .aimodel, .coreAIBundle, .mlx: false
        case .gguf, .safetensors, .transformers, .unknown: true
        }
    }

    /// The runtime contract for directly executable artifact formats.
    /// Conversion-required source formats intentionally return nil: their
    /// eventual runtime must be declared by the conversion output rather than
    /// guessed from the input weights.
    public var directRuntime: ArchonModelRuntime? {
        switch self {
        case .aimodel, .coreAIBundle: .coreAI
        case .mlx: .mlx
        case .gguf, .safetensors, .transformers, .unknown: nil
        }
    }
}

public enum ArchonModelSource: String, Codable, CaseIterable, Sendable {
    case appleCoreAI
    case huggingFace
    case archonRegistry
    case developerRegistry
    case directURL
    case localImport
}

public struct ModelLicenseMetadata: Codable, Equatable, Sendable {
    public let identifier: String?
    public let url: URL?

    public init(identifier: String? = nil, url: URL? = nil) {
        self.identifier = identifier
        self.url = url
    }

    public var licenseIdentifier: String? { identifier }
    public var licenseURL: URL? { url }
}

public struct ModelCapabilityRequirements: Codable, Equatable, Sendable {
    public let task: ArchonModelTask
    public let requiresStreaming: Bool
    public let requiresToolCalling: Bool
    public let requiresStructuredOutput: Bool

    public init(
        task: ArchonModelTask,
        requiresStreaming: Bool = false,
        requiresToolCalling: Bool = false,
        requiresStructuredOutput: Bool = false
    ) {
        self.task = task
        self.requiresStreaming = requiresStreaming
        self.requiresToolCalling = requiresToolCalling
        self.requiresStructuredOutput = requiresStructuredOutput
    }
}

/// Runtime capabilities derived from an Archon model manifest. This is
/// metadata negotiation only; the runtime adapter still owns actual loading.
public struct ModelRuntimeCapabilities: Codable, Equatable, Sendable {
    public let runtime: ArchonModelRuntime
    public let tasks: Set<ArchonModelTask>
    public let supportsStreaming: Bool
    public let supportsToolCalling: Bool
    public let supportsStructuredOutput: Bool

    public init(
        runtime: ArchonModelRuntime,
        capabilities: ArchonModelCapabilities
    ) {
        self.runtime = runtime
        self.tasks = capabilities.tasks
        self.supportsStreaming = capabilities.supportsStreaming
        self.supportsToolCalling = capabilities.supportsToolCalling
        self.supportsStructuredOutput = capabilities.supportsStructuredOutput
    }

    public func satisfies(_ requirements: ModelCapabilityRequirements) -> Bool {
        tasks.contains(requirements.task) &&
            (!requirements.requiresStreaming || supportsStreaming) &&
            (!requirements.requiresToolCalling || supportsToolCalling) &&
            (!requirements.requiresStructuredOutput || supportsStructuredOutput)
    }
}

public enum ModelLicenseDecision: String, Codable, CaseIterable, Sendable {
    case allowed
    case confirmationRequired
    case denied
}

public enum UnknownModelLicenseBehavior: String, Codable, CaseIterable, Sendable {
    case confirmationRequired
    case denied
    case allowed
}

/// Deterministic policy for deciding whether a model's declared license may be
/// installed. Unknown and custom licenses are never treated as implicitly safe
/// unless the caller explicitly selects `.allowed`.
public struct ModelLicensePolicy: Codable, Equatable, Sendable {
    public let allowedIdentifiers: Set<String>
    public let confirmationIdentifiers: Set<String>
    public let unknownBehavior: UnknownModelLicenseBehavior

    public init(
        allowedIdentifiers: Set<String> = ["apache-2.0", "mit", "bsd", "bsd-2-clause", "bsd-3-clause"],
        confirmationIdentifiers: Set<String> = [],
        unknownBehavior: UnknownModelLicenseBehavior = .confirmationRequired
    ) {
        self.allowedIdentifiers = Set(allowedIdentifiers.map(Self.normalize))
        self.confirmationIdentifiers = Set(confirmationIdentifiers.map(Self.normalize))
        self.unknownBehavior = unknownBehavior
    }

    public func decision(for license: ModelLicenseMetadata?) -> ModelLicenseDecision {
        guard let identifier = license?.identifier.map(Self.normalize), !identifier.isEmpty else {
            return decisionForUnknownLicense()
        }
        if allowedIdentifiers.contains(identifier) { return .allowed }
        if confirmationIdentifiers.contains(identifier) { return .confirmationRequired }
        return decisionForUnknownLicense()
    }

    private func decisionForUnknownLicense() -> ModelLicenseDecision {
        switch unknownBehavior {
        case .confirmationRequired: .confirmationRequired
        case .denied: .denied
        case .allowed: .allowed
        }
    }

    private static func normalize(_ identifier: String) -> String {
        identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
    }
}

public struct ModelResource: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let url: URL?
    public let relativePath: String
    public let sizeBytes: Int64?
    public let sha256: String?

    public init(
        id: String = UUID().uuidString,
        name: String,
        url: URL? = nil,
        relativePath: String,
        sizeBytes: Int64? = nil,
        sha256: String? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.relativePath = relativePath
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
    }
}

public struct ModelVariant: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let modelID: String
    public let source: ArchonModelSource
    public let downloadURL: URL?
    public let format: ArchonModelFormat
    public let runtime: ArchonModelRuntime
    public let architecture: String?
    public let supportedDeviceArchitectures: Set<String>
    public let supportedPlatforms: Set<ArchonPlatform>
    public let minimumOS: ArchonOSVersion?
    public let parameterCount: Int64?
    public let contextLength: Int?
    public let precision: String?
    public let quantization: String?
    /// Additional KV-cache memory required per context token, when known.
    public let kvCacheBytesPerToken: Int64?
    public let sizeBytes: Int64?
    /// Base resident artifact/weights estimate in bytes. The compatibility
    /// analyzer derives a higher predicted peak by adding runtime workspace,
    /// KV cache, and a safety margin.
    public let estimatedMemoryBytes: Int64?
    /// Optional normalized quality estimate supplied by a catalog or host.
    /// Archon never invents this value from a model name.
    public let estimatedQualityScore: Double?
    /// Optional expected generation speed, normally in tokens per second.
    public let estimatedTokensPerSecond: Double?
    public let sha256: String?
    public let resources: [ModelResource]
    public let tokenizerResources: [ModelResource]
    public let capabilities: ArchonModelCapabilities
    public let requiresAuthentication: Bool
    /// True when the artifact came from an export path that has not yet passed
    /// runtime, output, and device validation. Experimental variants are never
    /// treated as loadable by Archon.
    public let isExperimental: Bool

    public init(
        id: String,
        name: String,
        modelID: String,
        source: ArchonModelSource,
        downloadURL: URL? = nil,
        format: ArchonModelFormat,
        runtime: ArchonModelRuntime,
        architecture: String? = nil,
        supportedDeviceArchitectures: Set<String> = ["arm64"],
        supportedPlatforms: Set<ArchonPlatform> = Set(ArchonPlatform.allCases),
        minimumOS: ArchonOSVersion? = nil,
        parameterCount: Int64? = nil,
        contextLength: Int? = nil,
        precision: String? = nil,
        quantization: String? = nil,
        kvCacheBytesPerToken: Int64? = nil,
        sizeBytes: Int64? = nil,
        estimatedMemoryBytes: Int64? = nil,
        estimatedQualityScore: Double? = nil,
        estimatedTokensPerSecond: Double? = nil,
        sha256: String? = nil,
        resources: [ModelResource] = [],
        tokenizerResources: [ModelResource] = [],
        capabilities: ArchonModelCapabilities = ArchonModelCapabilities(),
        requiresAuthentication: Bool = false,
        isExperimental: Bool = false
    ) {
        self.id = id
        self.name = name
        self.modelID = modelID
        self.source = source
        self.downloadURL = downloadURL
        self.format = format
        self.runtime = runtime
        self.architecture = architecture
        self.supportedDeviceArchitectures = supportedDeviceArchitectures
        self.supportedPlatforms = supportedPlatforms
        self.minimumOS = minimumOS
        self.parameterCount = parameterCount
        self.contextLength = contextLength
        self.precision = precision
        self.quantization = quantization
        self.kvCacheBytesPerToken = kvCacheBytesPerToken
        self.sizeBytes = sizeBytes
        self.estimatedMemoryBytes = estimatedMemoryBytes
        self.estimatedQualityScore = estimatedQualityScore
        self.estimatedTokensPerSecond = estimatedTokensPerSecond
        self.sha256 = sha256
        self.resources = resources
        self.tokenizerResources = tokenizerResources
        self.capabilities = capabilities
        self.requiresAuthentication = requiresAuthentication
        self.isExperimental = isExperimental
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, modelID, source, downloadURL, format, runtime, architecture
        case supportedDeviceArchitectures, supportedPlatforms, minimumOS
        case parameterCount, contextLength, precision, quantization
        case kvCacheBytesPerToken, sizeBytes, estimatedMemoryBytes
        case estimatedQualityScore, estimatedTokensPerSecond, sha256
        case resources, tokenizerResources, capabilities, requiresAuthentication
        case isExperimental
    }

    /// Keeps catalogs written before the experimental marker readable.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            modelID: try container.decode(String.self, forKey: .modelID),
            source: try container.decode(ArchonModelSource.self, forKey: .source),
            downloadURL: try container.decodeIfPresent(URL.self, forKey: .downloadURL),
            format: try container.decode(ArchonModelFormat.self, forKey: .format),
            runtime: try container.decode(ArchonModelRuntime.self, forKey: .runtime),
            architecture: try container.decodeIfPresent(String.self, forKey: .architecture),
            supportedDeviceArchitectures: try container.decodeIfPresent(Set<String>.self, forKey: .supportedDeviceArchitectures) ?? ["arm64"],
            supportedPlatforms: try container.decodeIfPresent(Set<ArchonPlatform>.self, forKey: .supportedPlatforms) ?? Set(ArchonPlatform.allCases),
            minimumOS: try container.decodeIfPresent(ArchonOSVersion.self, forKey: .minimumOS),
            parameterCount: try container.decodeIfPresent(Int64.self, forKey: .parameterCount),
            contextLength: try container.decodeIfPresent(Int.self, forKey: .contextLength),
            precision: try container.decodeIfPresent(String.self, forKey: .precision),
            quantization: try container.decodeIfPresent(String.self, forKey: .quantization),
            kvCacheBytesPerToken: try container.decodeIfPresent(Int64.self, forKey: .kvCacheBytesPerToken),
            sizeBytes: try container.decodeIfPresent(Int64.self, forKey: .sizeBytes),
            estimatedMemoryBytes: try container.decodeIfPresent(Int64.self, forKey: .estimatedMemoryBytes),
            estimatedQualityScore: try container.decodeIfPresent(Double.self, forKey: .estimatedQualityScore),
            estimatedTokensPerSecond: try container.decodeIfPresent(Double.self, forKey: .estimatedTokensPerSecond),
            sha256: try container.decodeIfPresent(String.self, forKey: .sha256),
            resources: try container.decodeIfPresent([ModelResource].self, forKey: .resources) ?? [],
            tokenizerResources: try container.decodeIfPresent([ModelResource].self, forKey: .tokenizerResources) ?? [],
            capabilities: try container.decodeIfPresent(ArchonModelCapabilities.self, forKey: .capabilities) ?? ArchonModelCapabilities(),
            requiresAuthentication: try container.decodeIfPresent(Bool.self, forKey: .requiresAuthentication) ?? false,
            isExperimental: try container.decodeIfPresent(Bool.self, forKey: .isExperimental) ?? false
        )
    }
}

public struct ModelDescriptor: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let publisher: String
    public let family: String?
    public let parameterCount: Int64?
    public let tasks: Set<ArchonModelTask>
    public let architecture: String?
    public let description: String?
    /// Optional provider-supplied artwork for model-management surfaces.
    /// A missing or unavailable image is expected; consumers must keep a
    /// native fallback visible.
    public let logoURL: URL?
    public let source: ArchonModelSource
    public let sourceURL: URL?
    public let revision: String?
    public let license: ModelLicenseMetadata?
    public let gated: Bool
    public let supportedLanguages: [String]
    public let variants: [ModelVariant]

    /// Convenience access to the declared license URL without requiring
    /// callers to unwrap the full license metadata value.
    public var licenseURL: URL? { license?.url }

    public init(
        id: String,
        name: String,
        publisher: String,
        family: String? = nil,
        parameterCount: Int64? = nil,
        tasks: Set<ArchonModelTask> = [.textGeneration],
        architecture: String? = nil,
        description: String? = nil,
        logoURL: URL? = nil,
        source: ArchonModelSource,
        sourceURL: URL? = nil,
        revision: String? = nil,
        license: ModelLicenseMetadata? = nil,
        gated: Bool = false,
        supportedLanguages: [String] = [],
        variants: [ModelVariant] = []
    ) {
        self.id = id
        self.name = name
        self.publisher = publisher
        self.family = family
        self.parameterCount = parameterCount
        self.tasks = tasks
        self.architecture = architecture
        self.description = description
        self.logoURL = logoURL
        self.source = source
        self.sourceURL = sourceURL
        self.revision = revision
        self.license = license
        self.gated = gated
        self.supportedLanguages = supportedLanguages
        self.variants = variants
    }
}

public struct ModelSearchRequest: Sendable {
    public var query: String
    public var task: ArchonModelTask?
    public var runtime: ArchonModelRuntime?
    public var format: ArchonModelFormat?
    public var compatibleOnly: Bool
    public var device: ArchonDeviceCapabilities?
    /// Zero-based position used by catalogs that paginate with offsets.
    /// Cursor-based catalogs should prefer `continuationToken` instead.
    public var offset: Int
    /// Opaque continuation state returned by a paginated catalog. Callers must
    /// pass it back unchanged and must not inspect or persist its contents as a
    /// provider-specific contract.
    public var continuationToken: String?
    public var limit: Int
    public var includeVariants: Bool

    public init(
        query: String,
        task: ArchonModelTask? = nil,
        runtime: ArchonModelRuntime? = nil,
        format: ArchonModelFormat? = nil,
        compatibleOnly: Bool = false,
        device: ArchonDeviceCapabilities? = nil,
        offset: Int = 0,
        continuationToken: String? = nil,
        limit: Int = 20,
        includeVariants: Bool = true
    ) {
        self.query = query
        self.task = task
        self.runtime = runtime
        self.format = format
        self.compatibleOnly = compatibleOnly
        self.device = device
        self.offset = max(0, offset)
        self.continuationToken = continuationToken
        self.limit = max(1, min(limit, 100))
        self.includeVariants = includeVariants
    }
}

/// A bounded result page returned by a catalog that supports incremental
/// discovery. `nextContinuationToken` is provider-owned opaque state.
public struct ModelCatalogPage: Sendable, Equatable {
    public let models: [ModelDescriptor]
    public let hasMore: Bool
    public let nextContinuationToken: String?

    public init(
        models: [ModelDescriptor],
        hasMore: Bool,
        nextContinuationToken: String? = nil
    ) {
        self.models = models
        self.hasMore = hasMore
        self.nextContinuationToken = nextContinuationToken
    }
}

public protocol ModelCatalogProvider: Sendable {
    var id: String { get }
    func search(_ request: ModelSearchRequest) async throws -> [ModelDescriptor]
}

/// Optional pagination boundary for catalogs that can report whether another
/// page exists. Existing custom `ModelCatalogProvider` implementations remain
/// source-compatible and are used through their bounded `search` method.
public protocol PaginatedModelCatalogProvider: ModelCatalogProvider {
    func searchPage(_ request: ModelSearchRequest) async throws -> ModelCatalogPage
}

/// A strict user-facing catalog boundary for locally runnable MLX models.
///
/// The wrapped provider may contain Core AI, Foundation Models, remote, or
/// conversion-required entries, but this catalog never returns them. It also
/// preserves pagination by carrying the wrapped provider's offset/cursor in an
/// opaque continuation token while it skips non-MLX pages.
public struct MLXModelCatalog: PaginatedModelCatalogProvider, Sendable {
    public let id: String
    private let provider: any ModelCatalogProvider

    public init(provider: any ModelCatalogProvider) {
        self.id = "mlx-only.\(provider.id)"
        self.provider = provider
    }

    public func search(_ request: ModelSearchRequest) async throws -> [ModelDescriptor] {
        try await searchPage(request).models
    }

    public func searchPage(_ request: ModelSearchRequest) async throws -> ModelCatalogPage {
        guard request.runtime == nil || request.runtime == .mlx,
              request.format == nil || request.format == .mlx else {
            return ModelCatalogPage(models: [], hasMore: false)
        }

        var state = try ContinuationState.decode(request.continuationToken)
        if request.continuationToken == nil {
            state = ContinuationState(offset: request.offset, token: nil)
        }

        guard let paginatedProvider = provider as? any PaginatedModelCatalogProvider else {
            var mlxRequest = request
            mlxRequest.runtime = .mlx
            mlxRequest.format = .mlx
            mlxRequest.includeVariants = true
            let models = try await provider.search(mlxRequest)
                .compactMap { Self.mlxDescriptor($0, includeVariants: request.includeVariants) }
            return ModelCatalogPage(models: Array(models.prefix(request.limit)), hasMore: false)
        }

        var models: [ModelDescriptor] = []
        var hasMore = false
        var lastState = state
        var visitedStates = Set<ContinuationState>()

        // A provider page can contain descriptors with no MLX variant even
        // after a runtime filter. Advance through a small bounded number of
        // pages so those entries cannot starve the user-visible MLX results.
        for _ in 0..<8 where models.count < request.limit {
            guard visitedStates.insert(lastState).inserted else { break }

            var mlxRequest = request
            mlxRequest.runtime = .mlx
            mlxRequest.format = .mlx
            mlxRequest.includeVariants = true
            mlxRequest.offset = lastState.offset
            mlxRequest.continuationToken = lastState.token

            let page = try await paginatedProvider.searchPage(mlxRequest)
            models.append(contentsOf: page.models.compactMap {
                Self.mlxDescriptor($0, includeVariants: request.includeVariants)
            })
            if models.count > request.limit {
                models = Array(models.prefix(request.limit))
            }

            let nextState = ContinuationState(
                offset: lastState.offset + page.models.count,
                token: page.nextContinuationToken
            )
            let madeProgress: Bool
            if lastState.token != nil {
                // Cursor providers make offset state meaningless. A repeated
                // cursor must stop rather than fetching the same page again.
                madeProgress = nextState.token != lastState.token
            } else {
                madeProgress = page.models.count > 0 || nextState.token != nil
            }
            hasMore = page.hasMore && madeProgress
            lastState = nextState
            guard hasMore else { break }
        }

        let continuation = hasMore ? try lastState.encoded() : nil
        return ModelCatalogPage(
            models: models,
            hasMore: hasMore,
            nextContinuationToken: continuation
        )
    }

    private static func mlxDescriptor(
        _ model: ModelDescriptor,
        includeVariants: Bool
    ) -> ModelDescriptor? {
        let variants = model.variants.filter {
            $0.runtime == .mlx && $0.format == .mlx
        }
        guard !variants.isEmpty else { return nil }
        return ModelDescriptor(
            id: model.id,
            name: model.name,
            publisher: model.publisher,
            family: model.family,
            parameterCount: model.parameterCount,
            tasks: model.tasks,
            architecture: model.architecture,
            description: model.description,
            logoURL: model.logoURL,
            source: model.source,
            sourceURL: model.sourceURL,
            revision: model.revision,
            license: model.license,
            gated: model.gated,
            supportedLanguages: model.supportedLanguages,
            variants: includeVariants ? variants : []
        )
    }

    private struct ContinuationState: Codable, Equatable, Hashable, Sendable {
        let offset: Int
        let token: String?

        static func decode(_ value: String?) throws -> ContinuationState {
            guard let value else { return ContinuationState(offset: 0, token: nil) }
            guard let data = Data(base64Encoded: value),
                  let state = try? JSONDecoder().decode(ContinuationState.self, from: data) else {
                throw ArchonModelsError.invalidResponse
            }
            return state
        }

        func encoded() throws -> String {
            try JSONEncoder().encode(self).base64EncodedString()
        }
    }
}

/// Trust policy for user-facing official model discovery.
///
/// Officialness is based on the model publisher's namespace, not on a model
/// name, family label, or a community conversion repository. Hugging Face
/// entries must keep the same allow-listed namespace for both the descriptor
/// and its MLX variant. Registry-backed descriptors use the publisher and
/// variant namespace as the host-owned provenance contract.
public struct OfficialModelCatalogPolicy: Sendable, Equatable {
    public let allowedHuggingFaceOrganizations: Set<String>

    /// A conservative first-party namespace set for openly published model
    /// repositories. Community conversion namespaces such as
    /// `mlx-community` are intentionally absent and can never pass the
    /// default policy.
    public static let defaultHuggingFaceOrganizations: Set<String> = [
        "01-ai",
        "ai21labs",
        "allenai",
        "apple",
        "cohere",
        "databricks",
        "deepseek-ai",
        "google",
        "google-bert",
        "ibm-granite",
        "meta-llama",
        "microsoft",
        "mistralai",
        "moonshotai",
        "nvidia",
        "openai",
        "qwen",
        "tiiuae"
    ]

    public init(
        allowedHuggingFaceOrganizations: Set<String> = Self.defaultHuggingFaceOrganizations
    ) {
        self.allowedHuggingFaceOrganizations = Set(
            allowedHuggingFaceOrganizations.map(Self.normalize)
        )
    }

    /// Returns true only when the descriptor and its variant identify the
    /// same allow-listed first-party namespace.
    public func accepts(_ model: ModelDescriptor, variant: ModelVariant) -> Bool {
        guard model.source == variant.source else { return false }

        switch model.source {
        case .huggingFace:
            guard let modelOwner = Self.repositoryOwner(model.id),
                  let variantOwner = Self.repositoryOwner(variant.modelID),
                  modelOwner == variantOwner,
                  allowedHuggingFaceOrganizations.contains(modelOwner) else {
                return false
            }
            return true
        case .archonRegistry, .appleCoreAI:
            guard allowedHuggingFaceOrganizations.contains(Self.normalize(model.publisher)) else {
                return false
            }
            guard let variantOwner = Self.repositoryOwner(variant.modelID) else {
                return true
            }
            return allowedHuggingFaceOrganizations.contains(variantOwner)
        case .developerRegistry, .directURL, .localImport:
            return false
        }
    }

    private static func repositoryOwner(_ identifier: String) -> String? {
        let components = identifier.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 2 else { return nil }
        return normalize(String(components[0]))
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// A strict user-facing catalog boundary for official, locally runnable MLX
/// models. It composes the MLX runtime/format gate with a publisher namespace
/// gate, so community conversions and arbitrary developer entries cannot
/// appear in the model browser.
public struct OfficialModelCatalog: PaginatedModelCatalogProvider, Sendable {
    public let id: String
    public let policy: OfficialModelCatalogPolicy
    private let catalog: MLXModelCatalog

    public init(
        provider: any ModelCatalogProvider,
        policy: OfficialModelCatalogPolicy = OfficialModelCatalogPolicy()
    ) {
        let mlxCatalog = MLXModelCatalog(provider: provider)
        self.id = "official.\(mlxCatalog.id)"
        self.policy = policy
        self.catalog = mlxCatalog
    }

    public func search(_ request: ModelSearchRequest) async throws -> [ModelDescriptor] {
        try await searchPage(request).models
    }

    public func searchPage(_ request: ModelSearchRequest) async throws -> ModelCatalogPage {
        guard request.runtime == nil || request.runtime == .mlx,
              request.format == nil || request.format == .mlx else {
            return ModelCatalogPage(models: [], hasMore: false)
        }

        var state = try ContinuationState.decode(request.continuationToken)
        if request.continuationToken == nil {
            state = ContinuationState(offset: request.offset, token: nil)
        }

        var models: [ModelDescriptor] = []
        var hasMore = false
        var lastState = state
        var visitedStates = Set<ContinuationState>()

        // A remote catalog can return many community entries before an
        // official package. Keep skipping bounded and expose an opaque cursor
        // so the caller can explicitly request another page.
        for _ in 0..<8 where models.count < request.limit {
            guard visitedStates.insert(lastState).inserted else { break }

            var mlxRequest = request
            mlxRequest.runtime = .mlx
            mlxRequest.format = .mlx
            mlxRequest.includeVariants = true
            mlxRequest.offset = lastState.offset
            mlxRequest.continuationToken = lastState.token

            let page = try await catalog.searchPage(mlxRequest)
            models.append(contentsOf: page.models.compactMap {
                officialDescriptor($0, includeVariants: request.includeVariants)
            })
            if models.count > request.limit {
                models = Array(models.prefix(request.limit))
            }

            let nextState = ContinuationState(
                offset: lastState.offset + page.models.count,
                token: page.nextContinuationToken
            )
            let madeProgress: Bool
            if lastState.token != nil {
                madeProgress = nextState.token != lastState.token
            } else {
                madeProgress = page.models.count > 0 || nextState.token != nil
            }
            hasMore = page.hasMore && madeProgress
            lastState = nextState
            guard hasMore else { break }
        }

        return ModelCatalogPage(
            models: models,
            hasMore: hasMore,
            nextContinuationToken: hasMore ? try lastState.encoded() : nil
        )
    }

    private func officialDescriptor(
        _ model: ModelDescriptor,
        includeVariants: Bool
    ) -> ModelDescriptor? {
        let variants = model.variants.filter { policy.accepts(model, variant: $0) }
        guard !variants.isEmpty else { return nil }
        return ModelDescriptor(
            id: model.id,
            name: model.name,
            publisher: model.publisher,
            family: model.family,
            parameterCount: model.parameterCount,
            tasks: model.tasks,
            architecture: model.architecture,
            description: model.description,
            logoURL: model.logoURL,
            source: model.source,
            sourceURL: model.sourceURL,
            revision: model.revision,
            license: model.license,
            gated: model.gated,
            supportedLanguages: model.supportedLanguages,
            variants: includeVariants ? variants : []
        )
    }

    private struct ContinuationState: Codable, Equatable, Hashable, Sendable {
        let offset: Int
        let token: String?

        static func decode(_ value: String?) throws -> ContinuationState {
            guard let value else { return ContinuationState(offset: 0, token: nil) }
            guard let data = Data(base64Encoded: value),
                  let state = try? JSONDecoder().decode(ContinuationState.self, from: data) else {
                throw ArchonModelsError.invalidResponse
            }
            return state
        }

        func encoded() throws -> String {
            try JSONEncoder().encode(self).base64EncodedString()
        }
    }
}

public struct StaticModelCatalog: PaginatedModelCatalogProvider, Sendable {
    public let id: String
    public let models: [ModelDescriptor]

    public init(id: String = "static", models: [ModelDescriptor]) {
        self.id = id
        self.models = models
    }

    public func search(_ request: ModelSearchRequest) async throws -> [ModelDescriptor] {
        try await searchPage(request).models
    }

    public func searchPage(_ request: ModelSearchRequest) async throws -> ModelCatalogPage {
        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filteredModels: [ModelDescriptor] = models
            .filter { query.isEmpty || $0.id.lowercased().contains(query) || $0.name.lowercased().contains(query) }
            .filter { model in
                guard let task = request.task else { return true }
                return model.tasks.contains(task)
            }
            .compactMap { (model: ModelDescriptor) -> ModelDescriptor? in
                let variants = model.variants.filter { variant in
                    (request.runtime == nil || variant.runtime == request.runtime) &&
                    (request.format == nil || variant.format == request.format) &&
                    (!request.compatibleOnly || request.device.map { ModelCompatibilityAnalyzer.analyze(variant: variant, device: $0).canLoad } == true)
                }
                guard !request.compatibleOnly || !variants.isEmpty else { return nil }
                return ModelDescriptor(
                    id: model.id,
                    name: model.name,
                    publisher: model.publisher,
                    family: model.family,
                    parameterCount: model.parameterCount,
                    tasks: model.tasks,
                    architecture: model.architecture,
                    description: model.description,
                    logoURL: model.logoURL,
                    source: model.source,
                    sourceURL: model.sourceURL,
                    revision: model.revision,
                    license: model.license,
                    gated: model.gated,
                    supportedLanguages: model.supportedLanguages,
                    variants: request.includeVariants ? variants : []
                )
            }

        let page = Array(filteredModels.dropFirst(min(request.offset, filteredModels.count)).prefix(request.limit))
        return ModelCatalogPage(
            models: page,
            hasMore: request.offset + page.count < filteredModels.count
        )
    }
}

/// A catalog for one explicitly supplied remote model URL. The URL is metadata,
/// not a compatibility claim: raw formats still remain conversion-required.
public struct DirectURLModelCatalog: PaginatedModelCatalogProvider, Sendable {
    private let catalog: StaticModelCatalog

    public init(
        url: URL,
        modelID: String,
        modelName: String,
        publisher: String = "Direct URL",
        format: ArchonModelFormat,
        runtime: ArchonModelRuntime,
        architecture: String? = nil,
        supportedPlatforms: Set<ArchonPlatform> = Set(ArchonPlatform.allCases),
        minimumOS: ArchonOSVersion? = nil,
        parameterCount: Int64? = nil,
        contextLength: Int? = nil,
        precision: String? = nil,
        quantization: String? = nil,
        kvCacheBytesPerToken: Int64? = nil,
        sizeBytes: Int64? = nil,
        sha256: String? = nil,
        estimatedQualityScore: Double? = nil,
        estimatedTokensPerSecond: Double? = nil,
        license: ModelLicenseMetadata? = nil,
        requiresAuthentication: Bool = false,
        logoURL: URL? = nil
    ) {
        let variant = ModelVariant(
            id: "direct://\(modelID)",
            name: modelName,
            modelID: modelID,
            source: .directURL,
            downloadURL: url,
            format: format,
            runtime: runtime,
            architecture: architecture,
            supportedPlatforms: supportedPlatforms,
            minimumOS: minimumOS,
            parameterCount: parameterCount,
            contextLength: contextLength,
            precision: precision,
            quantization: quantization,
            kvCacheBytesPerToken: kvCacheBytesPerToken,
            sizeBytes: sizeBytes,
            estimatedQualityScore: estimatedQualityScore,
            estimatedTokensPerSecond: estimatedTokensPerSecond,
            sha256: sha256,
            requiresAuthentication: requiresAuthentication
        )
        let descriptor = ModelDescriptor(
            id: modelID,
            name: modelName,
            publisher: publisher,
            parameterCount: parameterCount,
            architecture: architecture,
            logoURL: logoURL,
            source: .directURL,
            sourceURL: url,
            license: license,
            variants: [variant]
        )
        self.catalog = StaticModelCatalog(id: "direct-url", models: [descriptor])
    }

    public var id: String { catalog.id }

    public func search(_ request: ModelSearchRequest) async throws -> [ModelDescriptor] {
        try await searchPage(request).models
    }

    public func searchPage(_ request: ModelSearchRequest) async throws -> ModelCatalogPage {
        try await catalog.searchPage(request)
    }
}

/// Discovers Archon model manifests from a local managed-library directory or
/// a list of explicit model package directories. Local discovery never creates
/// a download URL; callers can import the advertised `sourceURL` with the
/// manifest through `ModelLibrary.importArtifact(at:manifest:)`.
public struct LocalModelCatalog: PaginatedModelCatalogProvider, Sendable {
    public let locations: [URL]

    public init(locations: [URL]) {
        self.locations = locations
    }

    public var id: String { "local" }

    public func search(_ request: ModelSearchRequest) async throws -> [ModelDescriptor] {
        try await searchPage(request).models
    }

    public func searchPage(_ request: ModelSearchRequest) async throws -> ModelCatalogPage {
        var descriptors: [ModelDescriptor] = []
        var seen = Set<String>()
        for location in locations {
            for directory in candidateDirectories(at: location) {
                guard let descriptor = descriptor(at: directory), seen.insert(descriptor.id).inserted else { continue }
                descriptors.append(descriptor)
            }
        }

        return try await StaticModelCatalog(id: id, models: descriptors).searchPage(request)
    }

    private func candidateDirectories(at location: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: location.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { return [] }

        let manifestURL = location.appendingPathComponent(ArchonModelManifest.filename)
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            return [location]
        }

        return (try? FileManager.default.contentsOfDirectory(
            at: location,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ))?.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true &&
                FileManager.default.fileExists(atPath: $0.appendingPathComponent(ArchonModelManifest.filename).path)
        } ?? []
    }

    private func descriptor(at directory: URL) -> ModelDescriptor? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(ArchonModelManifest.filename)),
              let manifest = try? JSONDecoder().decode(ArchonModelManifest.self, from: data) else { return nil }

        let variant = ModelVariant(
            id: "local://\(directory.lastPathComponent)",
            name: manifest.modelName,
            modelID: manifest.modelID,
            source: .localImport,
            format: manifest.format,
            runtime: manifest.runtime,
            architecture: manifest.architecture,
            supportedDeviceArchitectures: manifest.supportedDeviceArchitectures,
            supportedPlatforms: manifest.platforms,
            minimumOS: manifest.minimumOS,
            parameterCount: manifest.parameterCount,
            contextLength: manifest.contextLength,
            precision: manifest.precision,
            quantization: manifest.quantization,
            kvCacheBytesPerToken: manifest.kvCacheBytesPerToken,
            sizeBytes: manifest.modelSizeBytes,
            estimatedMemoryBytes: manifest.estimatedMemoryBytes,
            estimatedQualityScore: manifest.estimatedQualityScore,
            estimatedTokensPerSecond: manifest.estimatedTokensPerSecond,
            sha256: manifest.checksum,
            resources: manifest.modelResources,
            tokenizerResources: manifest.tokenizerResources,
            capabilities: manifest.capabilities,
            isExperimental: manifest.isExperimental
        )
        return ModelDescriptor(
            id: "local://\(directory.lastPathComponent)",
            name: manifest.modelName,
            publisher: "Local",
            parameterCount: manifest.parameterCount,
            architecture: manifest.architecture,
            logoURL: manifest.logoURL,
            source: .localImport,
            sourceURL: directory,
            revision: manifest.sourceRevision,
            license: manifest.license,
            variants: [variant]
        )
    }
}

/// A catalog adapter for curated Apple Core AI entries. The entries are supplied by
/// the application or a checked-in registry so the SDK never invents runtime support.
public struct AppleCoreAIModelCatalog: PaginatedModelCatalogProvider, Sendable {
    private let provider: any ModelCatalogProvider

    public init(models: [ModelDescriptor] = []) {
        self.provider = StaticModelCatalog(id: "apple-coreai", models: models)
    }

    public init(
        endpoint: URL,
        session: any ModelHTTPClient = URLSession.shared,
        headers: [String: String] = [:],
        tokenStore: (any ModelTokenStore)? = nil,
        tokenService: String? = "apple-coreai"
    ) {
        self.provider = RemoteModelCatalog(
            id: "apple-coreai",
            endpoint: endpoint,
            session: session,
            headers: headers,
            tokenStore: tokenStore,
            tokenService: tokenService
        )
    }

    public var id: String { provider.id }

    public func search(_ request: ModelSearchRequest) async throws -> [ModelDescriptor] {
        try await searchPage(request).models
    }

    public func searchPage(_ request: ModelSearchRequest) async throws -> ModelCatalogPage {
        if let provider = provider as? any PaginatedModelCatalogProvider {
            return try await provider.searchPage(request)
        }
        let models = try await provider.search(request)
        return ModelCatalogPage(models: models, hasMore: models.count == request.limit)
    }
}

/// A developer-hosted Archon-compatible catalog. It is intentionally data-driven;
/// VM451 infrastructure is not required for publishing or consuming entries.
public struct ArchonCompatibleModelCatalog: PaginatedModelCatalogProvider, Sendable {
    private let provider: any ModelCatalogProvider

    public init(models: [ModelDescriptor] = []) {
        self.provider = StaticModelCatalog(id: "archon-registry", models: models)
    }

    public init(
        endpoint: URL,
        session: any ModelHTTPClient = URLSession.shared,
        headers: [String: String] = [:],
        tokenStore: (any ModelTokenStore)? = nil,
        tokenService: String? = "archon-registry"
    ) {
        self.provider = RemoteModelCatalog(
            id: "archon-registry",
            endpoint: endpoint,
            session: session,
            headers: headers,
            tokenStore: tokenStore,
            tokenService: tokenService
        )
    }

    public var id: String { provider.id }

    public func search(_ request: ModelSearchRequest) async throws -> [ModelDescriptor] {
        try await searchPage(request).models
    }

    public func searchPage(_ request: ModelSearchRequest) async throws -> ModelCatalogPage {
        if let provider = provider as? any PaginatedModelCatalogProvider {
            return try await provider.searchPage(request)
        }
        let models = try await provider.search(request)
        return ModelCatalogPage(models: models, hasMore: models.count == request.limit)
    }
}

public struct CompositeModelCatalog: PaginatedModelCatalogProvider, Sendable {
    public let id: String
    public let providers: [any ModelCatalogProvider]

    public init(id: String = "composite", providers: [any ModelCatalogProvider]) {
        self.id = id
        self.providers = providers
    }

    public func search(_ request: ModelSearchRequest) async throws -> [ModelDescriptor] {
        try await searchPage(request).models
    }

    public func searchPage(_ request: ModelSearchRequest) async throws -> ModelCatalogPage {
        var results: [ModelDescriptor] = []
        var seen = Set<String>()
        var state = try Self.state(from: request.continuationToken, providerCount: providers.count)
        if request.continuationToken == nil, !state.offsets.isEmpty {
            state.offsets[0] = request.offset
        }

        while state.providerIndex < providers.count {
            let providerIndex = state.providerIndex
            let provider = providers[providerIndex]
            let providerRequest = ModelSearchRequest(
                query: request.query,
                task: request.task,
                runtime: request.runtime,
                format: request.format,
                compatibleOnly: request.compatibleOnly,
                device: request.device,
                offset: state.offsets[providerIndex],
                continuationToken: state.continuationTokens[providerIndex],
                limit: request.limit,
                includeVariants: request.includeVariants
            )
            let page: ModelCatalogPage
            if let paginatedProvider = provider as? any PaginatedModelCatalogProvider {
                page = try await paginatedProvider.searchPage(providerRequest)
            } else {
                let models = try await provider.search(providerRequest)
                page = ModelCatalogPage(
                    models: Array(models.prefix(request.limit)),
                    hasMore: models.count >= request.limit
                )
            }

            state.offsets[providerIndex] += page.models.count
            state.continuationTokens[providerIndex] = page.nextContinuationToken
            for model in page.models where seen.insert(model.id).inserted {
                results.append(model)
            }

            if page.hasMore {
                return ModelCatalogPage(
                    models: Array(results.prefix(request.limit)),
                    hasMore: true,
                    nextContinuationToken: try Self.token(for: state)
                )
            }

            state.providerIndex += 1
            if results.count >= request.limit || state.providerIndex == providers.count {
                let hasMore = state.providerIndex < providers.count
                return ModelCatalogPage(
                    models: Array(results.prefix(request.limit)),
                    hasMore: hasMore,
                    nextContinuationToken: hasMore ? try Self.token(for: state) : nil
                )
            }
        }
        return ModelCatalogPage(models: Array(results.prefix(request.limit)), hasMore: false)
    }

    private static func token(for state: CompositeContinuationState) throws -> String {
        try JSONEncoder().encode(state).base64EncodedString()
    }

    private static func state(
        from continuationToken: String?,
        providerCount: Int
    ) throws -> CompositeContinuationState {
        guard let continuationToken else {
            return CompositeContinuationState(
                providerIndex: 0,
                offsets: Array(repeating: 0, count: providerCount),
                continuationTokens: Array(repeating: nil, count: providerCount)
            )
        }
        guard let data = Data(base64Encoded: continuationToken),
              let state = try? JSONDecoder().decode(CompositeContinuationState.self, from: data),
              state.providerIndex >= 0,
              state.providerIndex <= providerCount,
              state.offsets.count == providerCount,
              state.continuationTokens.count == providerCount else {
            throw ArchonModelsError.invalidResponse
        }
        return state
    }
}

private struct CompositeContinuationState: Codable, Sendable {
    var providerIndex: Int
    var offsets: [Int]
    var continuationTokens: [String?]
}

public enum ModelCompatibilityStatus: String, Codable, CaseIterable, Sendable {
    case ready
    case compatible
    case conversionRequired
    case unsupportedFormat
    case unsupportedArchitecture
    case unsupportedOnDevice
    case insufficientMemory
    case memoryEstimateUnavailable
    case macOSOnly
    case iOSCompatible
    case requiresNewerOS
    case requiresAuthentication
    case thermalConstrained
    case experimental

    public var displayName: String {
        switch self {
        case .ready: "Ready"
        case .compatible: "Compatible"
        case .conversionRequired: "Conversion required"
        case .unsupportedFormat: "Unsupported format"
        case .unsupportedArchitecture: "Unsupported architecture"
        case .unsupportedOnDevice: "Unsupported on this device"
        case .insufficientMemory: "Insufficient memory"
        case .memoryEstimateUnavailable: "Memory estimate unavailable"
        case .macOSOnly: "macOS only"
        case .iOSCompatible: "iOS compatible"
        case .requiresNewerOS: "Requires newer OS"
        case .requiresAuthentication: "Authentication required"
        case .thermalConstrained: "Thermally constrained"
        case .experimental: "Experimental"
        }
    }
}

public enum ModelFitRating: String, Codable, CaseIterable, Sendable {
    case excellentFit
    case goodFit
    case mayBeSlow
    case memoryConstrained
    case notRecommended
    case cannotRun

    public var displayName: String {
        switch self {
        case .excellentFit: "Excellent fit"
        case .goodFit: "Good fit"
        case .mayBeSlow: "May be slow"
        case .memoryConstrained: "Memory constrained"
        case .notRecommended: "Not recommended"
        case .cannotRun: "Cannot run"
        }
    }
}

public struct ModelCompatibility: Codable, Equatable, Sendable {
    public let status: ModelCompatibilityStatus
    public let fit: ModelFitRating
    public let reasons: [String]

    public init(status: ModelCompatibilityStatus, fit: ModelFitRating, reasons: [String] = []) {
        self.status = status
        self.fit = fit
        self.reasons = reasons
    }

    public var canLoad: Bool {
        status == .ready || status == .compatible
    }

    /// Whether the artifact may be downloaded right now. Downloading is
    /// cold network I/O; only loading/running heats the device, so a
    /// thermally constrained device may still download (and run later
    /// once cool). Every hard block (memory, OS, format, auth) still
    /// refuses here because `canLoad` is false for those too.
    public var canDownload: Bool {
        canLoad || status == .thermalConstrained
    }
}

/// A conservative peak-memory prediction for a directly runnable local model.
/// The estimate includes the artifact/weights base, runtime workspace, KV cache,
/// and a model-level safety margin. It is intentionally a rejection boundary,
/// not a promise that a model may safely consume the entire process limit.
public struct ModelPeakMemoryEstimate: Codable, Equatable, Sendable {
    public let artifactOrWeightsBytes: UInt64
    public let runtimeOverheadBytes: UInt64
    public let kvCacheBytes: UInt64
    public let safetyMarginBytes: UInt64
    public let peakBytes: UInt64
    public let isHeuristic: Bool

    public init(
        artifactOrWeightsBytes: UInt64,
        runtimeOverheadBytes: UInt64,
        kvCacheBytes: UInt64,
        safetyMarginBytes: UInt64,
        peakBytes: UInt64,
        isHeuristic: Bool
    ) {
        self.artifactOrWeightsBytes = artifactOrWeightsBytes
        self.runtimeOverheadBytes = runtimeOverheadBytes
        self.kvCacheBytes = kvCacheBytes
        self.safetyMarginBytes = safetyMarginBytes
        self.peakBytes = peakBytes
        self.isHeuristic = isHeuristic
    }
}

public enum ModelCompatibilityAnalyzer {
    public static func analyze(
        variant: ModelVariant,
        device: ArchonDeviceCapabilities,
        isInstalled: Bool = false,
        hasAuthentication: Bool = true,
        requirements: ModelCapabilityRequirements? = nil
    ) -> ModelCompatibility {
        if let requirements,
           !ModelRuntimeCapabilities(runtime: variant.runtime, capabilities: variant.capabilities).satisfies(requirements) {
            return ModelCompatibility(
                status: .unsupportedFormat,
                fit: .cannotRun,
                reasons: ["The model variant does not provide the requested runtime capability contract."]
            )
        }
        if variant.requiresAuthentication && !hasAuthentication {
            return ModelCompatibility(
                status: .requiresAuthentication,
                fit: .cannotRun,
                reasons: ["The model source requires an authenticated account."]
            )
        }

        if !variant.supportedPlatforms.contains(device.platform) {
            let status: ModelCompatibilityStatus = device.platform == .macOS ? .macOSOnly : .unsupportedOnDevice
            return ModelCompatibility(status: status, fit: .cannotRun, reasons: ["This variant does not declare support for \(device.platform.rawValue)."])
        }

        if let minimumOS = variant.minimumOS, device.osVersion < minimumOS {
            return ModelCompatibility(
                status: .requiresNewerOS,
                fit: .cannotRun,
                reasons: ["Requires OS \(minimumOS.stringValue) or newer."]
            )
        }

        if !variant.supportedDeviceArchitectures.isEmpty && !variant.supportedDeviceArchitectures.contains(device.deviceArchitecture) {
            return ModelCompatibility(
                status: .unsupportedArchitecture,
                fit: .cannotRun,
                reasons: ["The artifact does not support device architecture \(device.deviceArchitecture)."]
            )
        }

        if variant.runtime == .coreAI && !device.supportsCoreAI {
            return ModelCompatibility(status: .unsupportedOnDevice, fit: .cannotRun, reasons: ["Core AI is unavailable on this OS or device."])
        }

        if device.thermalState == .serious || device.thermalState == .critical {
            return ModelCompatibility(status: .thermalConstrained, fit: .notRecommended, reasons: ["Current thermal pressure is too high for safe model loading."])
        }

        if variant.format.requiresConversion {
            return ModelCompatibility(
                status: .conversionRequired,
                fit: .cannotRun,
                reasons: ["\(variant.format.rawValue) is not a directly runnable Archon artifact; convert it to a supported runtime representation first."]
            )
        }

        if let expectedRuntime = variant.format.directRuntime, variant.runtime != expectedRuntime {
            return ModelCompatibility(
                status: .unsupportedFormat,
                fit: .cannotRun,
                reasons: ["The \(variant.format.rawValue) artifact must declare the \(expectedRuntime.rawValue) runtime; Archon will not reinterpret it through \(variant.runtime.rawValue)."]
            )
        }

        if variant.isExperimental {
            return ModelCompatibility(
                status: .experimental,
                fit: .cannotRun,
                reasons: ["This export is Experimental until runtime, output, and device validation have passed."]
            )
        }

        let estimatedMemory = estimatedPeakMemoryBytes(for: variant)
        if isLocalRunnableRuntime(variant.runtime), estimatedMemory == nil {
            return ModelCompatibility(
                status: .memoryEstimateUnavailable,
                fit: .cannotRun,
                reasons: ["A peak-memory estimate is required before this local model can be offered on the device."]
            )
        }
        if let estimatedMemory, estimatedMemory > device.recommendedModelMemoryBytes {
            return ModelCompatibility(
                status: .insufficientMemory,
                fit: .cannotRun,
                reasons: [
                    "Predicted peak RAM \(byteCount(estimatedMemory)) exceeds the conservative model budget \(byteCount(device.recommendedModelMemoryBytes)).",
                    "The budget reserves space for the host app, runtime/framework allocations, loaded models, and dynamic memory pressure."
                ]
            )
        }

        if isInstalled {
            return ModelCompatibility(status: .ready, fit: fit(estimatedMemoryBytes: estimatedMemory, device: device), reasons: ["Installed and eligible for local inference."])
        }

        let fit = fit(estimatedMemoryBytes: estimatedMemory, device: device)
        let reason = fit == .notRecommended
            ? "Artifact is compatible, but current thermal pressure makes it unsuitable for immediate loading."
            : "Artifact format and device requirements are satisfied."
        return ModelCompatibility(status: .compatible, fit: fit, reasons: [reason])
    }

    private static func fit(estimatedMemoryBytes: UInt64?, device: ArchonDeviceCapabilities) -> ModelFitRating {
        guard let estimatedMemory = estimatedMemoryBytes else { return .goodFit }
        let budget = Double(device.recommendedModelMemoryBytes)
        let ratio = Double(estimatedMemory) / max(budget, 1)
        if ratio <= 0.45 { return .excellentFit }
        if ratio <= 0.70 { return .goodFit }
        if ratio <= 0.90 { return .mayBeSlow }
        return .memoryConstrained
    }

    /// Returns the predicted runtime peak for a local model. This is public so
    /// catalogs and consuming apps can show the same number used by filtering,
    /// download preflight, and model loading.
    public static func estimatedPeakMemoryBytes(for variant: ModelVariant) -> UInt64? {
        estimatedPeakMemory(for: variant)?.peakBytes
    }

    /// Returns the full peak-memory breakdown used by compatibility checks.
    public static func estimatedPeakMemory(for variant: ModelVariant) -> ModelPeakMemoryEstimate? {
        guard isLocalRunnableRuntime(variant.runtime) else { return nil }

        let baseEstimate: (bytes: UInt64, heuristic: Bool)?
        if let declared = variant.estimatedMemoryBytes, declared > 0 {
            baseEstimate = (UInt64(declared), true)
        } else if let parameterCount = variant.parameterCount,
                  parameterCount > 0,
                  let bytesPerParameter = bytesPerParameter(for: variant) {
            baseEstimate = (saturatingDoubleToUInt64(Double(parameterCount) * bytesPerParameter * 1.20), true)
        } else if let artifactBytes = artifactBytes(for: variant), artifactBytes > 0 {
            // The packaged size is a lower bound for weights plus metadata;
            // catalog producers should prefer a measured peak estimate.
            baseEstimate = (saturatingDoubleToUInt64(Double(artifactBytes) * 1.15), true)
        } else {
            return nil
        }

        guard let baseEstimate else { return nil }
        let runtimeMultiplier: Double
        switch variant.runtime {
        case .mlx: runtimeMultiplier = 0.35
        case .coreAI: runtimeMultiplier = 0.25
        case .foundationModels: runtimeMultiplier = 0.10
        case .remote, .unknown: runtimeMultiplier = 0
        }
        let runtimeOverhead = saturatingDoubleToUInt64(Double(baseEstimate.bytes) * runtimeMultiplier)

        let kvCache: UInt64
        if let kvBytesPerToken = variant.kvCacheBytesPerToken,
           kvBytesPerToken > 0,
           let contextLength = variant.contextLength,
           contextLength > 0 {
            kvCache = saturatingDoubleToUInt64(Double(kvBytesPerToken) * Double(contextLength))
        } else {
            // When architecture-level KV metadata is unavailable, reserve a
            // context-dependent fraction of the base allocation. This is less
            // precise than a measured KV formula but prevents unknown context
            // windows from bypassing the load gate.
            let contextMultiplier = min(
                max(Double(variant.contextLength ?? 4_096) / 4_096.0, 1.0),
                8.0
            )
            kvCache = saturatingDoubleToUInt64(Double(baseEstimate.bytes) * 0.10 * contextMultiplier)
        }

        let subtotal = saturatingAdd(baseEstimate.bytes, runtimeOverhead, kvCache)
        let safetyMargin = max(
            64 * 1_048_576,
            saturatingDoubleToUInt64(Double(subtotal) * 0.10)
        )
        return ModelPeakMemoryEstimate(
            artifactOrWeightsBytes: baseEstimate.bytes,
            runtimeOverheadBytes: runtimeOverhead,
            kvCacheBytes: kvCache,
            safetyMarginBytes: safetyMargin,
            peakBytes: saturatingAdd(subtotal, safetyMargin),
            isHeuristic: baseEstimate.heuristic || variant.kvCacheBytesPerToken == nil
        )
    }

    private static func isLocalRunnableRuntime(_ runtime: ArchonModelRuntime) -> Bool {
        // Foundation Models weights are managed by Apple's system runtime and
        // are not downloaded into this model library. Only custom local
        // artifacts need this package-owned peak-memory rejection gate.
        runtime == .mlx || runtime == .coreAI
    }

    private static func artifactBytes(for variant: ModelVariant) -> UInt64? {
        if let sizeBytes = variant.sizeBytes, sizeBytes > 0 {
            return UInt64(sizeBytes)
        }
        let resourceBytes = (variant.resources + variant.tokenizerResources)
            .compactMap(\.sizeBytes)
            .filter { $0 > 0 }
            .reduce(into: UInt64(0)) { total, value in
                total = saturatingAdd(total, UInt64(value))
            }
        return resourceBytes > 0 ? resourceBytes : nil
    }

    private static func byteCount(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .memory)
    }

    private static func saturatingAdd(_ values: UInt64...) -> UInt64 {
        values.reduce(into: UInt64(0)) { total, value in
            let (sum, overflow) = total.addingReportingOverflow(value)
            total = overflow ? UInt64.max : sum
        }
    }

    private static func saturatingDoubleToUInt64(_ value: Double) -> UInt64 {
        guard value.isFinite, value > 0 else { return 0 }
        return value >= Double(UInt64.max) ? UInt64.max : UInt64(value.rounded(.up))
    }

    private static func bytesPerParameter(for variant: ModelVariant) -> Double? {
        let value = (variant.precision ?? variant.quantization ?? "").lowercased()
        if value.contains("q2") || value.contains("int2") || value.contains("2-bit") { return 0.25 }
        if value.contains("q3") || value.contains("int3") || value.contains("3-bit") { return 0.375 }
        if value.contains("q4") || value.contains("int4") || value.contains("4-bit") { return 0.5 }
        if value.contains("q5") || value.contains("int5") || value.contains("5-bit") { return 0.625 }
        if value.contains("q6") || value.contains("int6") || value.contains("6-bit") { return 0.75 }
        if value.contains("q8") || value.contains("int8") || value.contains("8-bit") { return 1.0 }
        if value.contains("f16") || value.contains("fp16") || value.contains("bf16") || value.contains("float16") { return 2.0 }
        if value.contains("f32") || value.contains("fp32") || value.contains("float32") { return 4.0 }
        return nil
    }

    /// Chooses the best currently loadable variant using deterministic fit and
    /// runtime preferences. It never infers compatibility from model names.
    public static func recommendedVariant(
        for model: ModelDescriptor,
        device: ArchonDeviceCapabilities,
        task: ArchonModelTask? = nil
    ) -> ModelVariant? {
        model.variants
            .filter { variant in
                guard let task else { return true }
                return variant.capabilities.tasks.contains(task)
            }
            .compactMap { variant -> (ModelVariant, ModelCompatibility)? in
                let compatibility = analyze(variant: variant, device: device)
                guard compatibility.canLoad, compatibility.fit != .notRecommended else { return nil }
                return (variant, compatibility)
            }
            .sorted { lhs, rhs in
                let leftFit = fitRank(lhs.1.fit)
                let rightFit = fitRank(rhs.1.fit)
                if leftFit != rightFit { return leftFit < rightFit }

                let leftQuality = normalizedQuality(lhs.0.estimatedQualityScore)
                let rightQuality = normalizedQuality(rhs.0.estimatedQualityScore)
                if leftQuality != rightQuality { return leftQuality > rightQuality }

                let leftSpeed = normalizedSpeed(lhs.0.estimatedTokensPerSecond)
                let rightSpeed = normalizedSpeed(rhs.0.estimatedTokensPerSecond)
                if leftSpeed != rightSpeed { return leftSpeed > rightSpeed }

                let leftRuntime = runtimeRank(lhs.0.runtime)
                let rightRuntime = runtimeRank(rhs.0.runtime)
                if leftRuntime != rightRuntime { return leftRuntime < rightRuntime }
                return (lhs.0.sizeBytes ?? Int64.max, lhs.0.id) < (rhs.0.sizeBytes ?? Int64.max, rhs.0.id)
            }
            .first?.0
    }

    /// Lists loadable quantization choices from smallest to largest. This is
    /// useful when a preferred precision does not fit the current device.
    public static func quantizationAlternatives(
        for model: ModelDescriptor,
        device: ArchonDeviceCapabilities,
        task: ArchonModelTask? = nil
    ) -> [ModelVariant] {
        model.variants
            .filter { variant in
                guard let task else { return true }
                return variant.capabilities.tasks.contains(task)
            }
            .filter { variant in
                let compatibility = analyze(variant: variant, device: device)
                return compatibility.canLoad
            }
            .sorted { lhs, rhs in
                let left = (lhs.quantization ?? lhs.precision ?? "").lowercased()
                let right = (rhs.quantization ?? rhs.precision ?? "").lowercased()
                if left != right { return left < right }
                return (lhs.sizeBytes ?? Int64.max) < (rhs.sizeBytes ?? Int64.max)
            }
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

public struct ArchonModelManifest: Codable, Equatable, Sendable {
    public static let filename = "archon-model.json"
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let modelID: String
    public let modelName: String
    public let sourceRepository: String?
    public let sourceRevision: String?
    public let license: ModelLicenseMetadata?
    /// Optional catalog artwork retained with the managed installation so
    /// installed-model surfaces can keep their branding offline-capable with
    /// a native fallback when the URL is unavailable.
    public let logoURL: URL?
    public let runtime: ArchonModelRuntime
    public let format: ArchonModelFormat
    public let architecture: String?
    /// CPU/device architectures supported by the packaged artifact. This is
    /// deliberately separate from `architecture`, which identifies the model
    /// architecture (for example, Qwen3ForCausalLM).
    public let supportedDeviceArchitectures: Set<String>
    /// The file or directory name copied into the managed model directory.
    /// Resource paths are relative to this artifact root.
    public let artifactPath: String?
    public let modelResources: [ModelResource]
    public let tokenizerResources: [ModelResource]
    public let checksum: String?
    public let modelSizeBytes: Int64?
    public let parameterCount: Int64?
    public let platforms: Set<ArchonPlatform>
    public let minimumOS: ArchonOSVersion?
    public let contextLength: Int?
    public let precision: String?
    public let quantization: String?
    public let kvCacheBytesPerToken: Int64?
    /// Base resident artifact/weights estimate in bytes. The compatibility
    /// analyzer derives a higher predicted peak before allowing local loading.
    public let estimatedMemoryBytes: Int64?
    public let estimatedQualityScore: Double?
    public let estimatedTokensPerSecond: Double?
    public let capabilities: ArchonModelCapabilities
    /// Marks exports that still require runtime, output, and device validation.
    /// Experimental manifests remain discoverable for developer workflows but
    /// are not eligible for local model loading.
    public let isExperimental: Bool

    public init(variant: ModelVariant, modelName: String, license: ModelLicenseMetadata? = nil, logoURL: URL? = nil, sourceRepository: String? = nil, sourceRevision: String? = nil) {
        self.init(
            modelID: variant.modelID,
            modelName: modelName,
            sourceRepository: sourceRepository,
            sourceRevision: sourceRevision,
            license: license,
            logoURL: logoURL,
            runtime: variant.runtime,
            format: variant.format,
            architecture: variant.architecture,
            supportedDeviceArchitectures: variant.supportedDeviceArchitectures,
            artifactPath: nil,
            modelResources: variant.resources,
            tokenizerResources: variant.tokenizerResources,
            checksum: variant.sha256,
            modelSizeBytes: variant.sizeBytes,
            parameterCount: variant.parameterCount,
            platforms: variant.supportedPlatforms,
            minimumOS: variant.minimumOS,
            contextLength: variant.contextLength,
            precision: variant.precision,
            quantization: variant.quantization,
            kvCacheBytesPerToken: variant.kvCacheBytesPerToken,
            estimatedMemoryBytes: variant.estimatedMemoryBytes,
            estimatedQualityScore: variant.estimatedQualityScore,
            estimatedTokensPerSecond: variant.estimatedTokensPerSecond,
            capabilities: variant.capabilities,
            isExperimental: variant.isExperimental
        )
    }

    public init(
        schemaVersion: Int = ArchonModelManifest.currentSchemaVersion,
        modelID: String,
        modelName: String,
        sourceRepository: String? = nil,
        sourceRevision: String? = nil,
        license: ModelLicenseMetadata? = nil,
        logoURL: URL? = nil,
        runtime: ArchonModelRuntime,
        format: ArchonModelFormat,
        architecture: String? = nil,
        supportedDeviceArchitectures: Set<String> = [],
        artifactPath: String? = nil,
        modelResources: [ModelResource] = [],
        tokenizerResources: [ModelResource] = [],
        checksum: String? = nil,
        modelSizeBytes: Int64? = nil,
        parameterCount: Int64? = nil,
        platforms: Set<ArchonPlatform> = Set(ArchonPlatform.allCases),
        minimumOS: ArchonOSVersion? = nil,
        contextLength: Int? = nil,
        precision: String? = nil,
        quantization: String? = nil,
        kvCacheBytesPerToken: Int64? = nil,
        estimatedMemoryBytes: Int64? = nil,
        estimatedQualityScore: Double? = nil,
        estimatedTokensPerSecond: Double? = nil,
        capabilities: ArchonModelCapabilities = ArchonModelCapabilities(),
        isExperimental: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.modelID = modelID
        self.modelName = modelName
        self.sourceRepository = sourceRepository
        self.sourceRevision = sourceRevision
        self.license = license
        self.logoURL = logoURL
        self.runtime = runtime
        self.format = format
        self.architecture = architecture
        self.supportedDeviceArchitectures = supportedDeviceArchitectures
        self.artifactPath = artifactPath
        self.modelResources = modelResources
        self.tokenizerResources = tokenizerResources
        self.checksum = checksum
        self.modelSizeBytes = modelSizeBytes
        self.parameterCount = parameterCount
        self.platforms = platforms
        self.minimumOS = minimumOS
        self.contextLength = contextLength
        self.precision = precision
        self.quantization = quantization
        self.kvCacheBytesPerToken = kvCacheBytesPerToken
        self.estimatedMemoryBytes = estimatedMemoryBytes
        self.estimatedQualityScore = estimatedQualityScore
        self.estimatedTokensPerSecond = estimatedTokensPerSecond
        self.capabilities = capabilities
        self.isExperimental = isExperimental
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, modelID, modelName, sourceRepository, sourceRevision
        case license, logoURL, runtime, format, architecture, supportedDeviceArchitectures
        case artifactPath, modelResources, tokenizerResources, checksum
        case modelSizeBytes, parameterCount, platforms, minimumOS, contextLength
        case precision, quantization, kvCacheBytesPerToken, estimatedMemoryBytes
        case estimatedQualityScore, estimatedTokensPerSecond
        case capabilities, isExperimental
    }

    /// Decodes older manifests that predate `supportedDeviceArchitectures`.
    /// An omitted value means the package did not declare a device-architecture
    /// restriction; it must not be inferred from the model architecture name.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? ArchonModelManifest.currentSchemaVersion,
            modelID: try container.decode(String.self, forKey: .modelID),
            modelName: try container.decode(String.self, forKey: .modelName),
            sourceRepository: try container.decodeIfPresent(String.self, forKey: .sourceRepository),
            sourceRevision: try container.decodeIfPresent(String.self, forKey: .sourceRevision),
            license: try container.decodeIfPresent(ModelLicenseMetadata.self, forKey: .license),
            logoURL: try container.decodeIfPresent(URL.self, forKey: .logoURL),
            runtime: try container.decode(ArchonModelRuntime.self, forKey: .runtime),
            format: try container.decode(ArchonModelFormat.self, forKey: .format),
            architecture: try container.decodeIfPresent(String.self, forKey: .architecture),
            supportedDeviceArchitectures: try container.decodeIfPresent(Set<String>.self, forKey: .supportedDeviceArchitectures) ?? [],
            artifactPath: try container.decodeIfPresent(String.self, forKey: .artifactPath),
            modelResources: try container.decodeIfPresent([ModelResource].self, forKey: .modelResources) ?? [],
            tokenizerResources: try container.decodeIfPresent([ModelResource].self, forKey: .tokenizerResources) ?? [],
            checksum: try container.decodeIfPresent(String.self, forKey: .checksum),
            modelSizeBytes: try container.decodeIfPresent(Int64.self, forKey: .modelSizeBytes),
            parameterCount: try container.decodeIfPresent(Int64.self, forKey: .parameterCount),
            platforms: try container.decodeIfPresent(Set<ArchonPlatform>.self, forKey: .platforms) ?? Set(ArchonPlatform.allCases),
            minimumOS: try container.decodeIfPresent(ArchonOSVersion.self, forKey: .minimumOS),
            contextLength: try container.decodeIfPresent(Int.self, forKey: .contextLength),
            precision: try container.decodeIfPresent(String.self, forKey: .precision),
            quantization: try container.decodeIfPresent(String.self, forKey: .quantization),
            kvCacheBytesPerToken: try container.decodeIfPresent(Int64.self, forKey: .kvCacheBytesPerToken),
            estimatedMemoryBytes: try container.decodeIfPresent(Int64.self, forKey: .estimatedMemoryBytes),
            estimatedQualityScore: try container.decodeIfPresent(Double.self, forKey: .estimatedQualityScore),
            estimatedTokensPerSecond: try container.decodeIfPresent(Double.self, forKey: .estimatedTokensPerSecond),
            capabilities: try container.decodeIfPresent(ArchonModelCapabilities.self, forKey: .capabilities) ?? ArchonModelCapabilities(),
            isExperimental: try container.decodeIfPresent(Bool.self, forKey: .isExperimental) ?? false
        )
    }

    /// Returns a copy with the managed artifact location made explicit.
    public func withArtifactPath(_ artifactPath: String?) -> ArchonModelManifest {
        ArchonModelManifest(
            schemaVersion: schemaVersion,
            modelID: modelID,
            modelName: modelName,
            sourceRepository: sourceRepository,
            sourceRevision: sourceRevision,
            license: license,
            logoURL: logoURL,
            runtime: runtime,
            format: format,
            architecture: architecture,
            supportedDeviceArchitectures: supportedDeviceArchitectures,
            artifactPath: artifactPath,
            modelResources: modelResources,
            tokenizerResources: tokenizerResources,
            checksum: checksum,
            modelSizeBytes: modelSizeBytes,
            parameterCount: parameterCount,
            platforms: platforms,
            minimumOS: minimumOS,
            contextLength: contextLength,
            precision: precision,
            quantization: quantization,
            kvCacheBytesPerToken: kvCacheBytesPerToken,
            estimatedMemoryBytes: estimatedMemoryBytes,
            estimatedQualityScore: estimatedQualityScore,
            estimatedTokensPerSecond: estimatedTokensPerSecond,
            capabilities: capabilities,
            isExperimental: isExperimental
        )
    }

    /// Returns a copy written with the current manifest schema. Migrations are
    /// intentionally additive and preserve all data that this package knows.
    public func withCurrentSchemaVersion() -> ArchonModelManifest {
        ArchonModelManifest(
            schemaVersion: ArchonModelManifest.currentSchemaVersion,
            modelID: modelID,
            modelName: modelName,
            sourceRepository: sourceRepository,
            sourceRevision: sourceRevision,
            license: license,
            logoURL: logoURL,
            runtime: runtime,
            format: format,
            architecture: architecture,
            supportedDeviceArchitectures: supportedDeviceArchitectures,
            artifactPath: artifactPath,
            modelResources: modelResources,
            tokenizerResources: tokenizerResources,
            checksum: checksum,
            modelSizeBytes: modelSizeBytes,
            parameterCount: parameterCount,
            platforms: platforms,
            minimumOS: minimumOS,
            contextLength: contextLength,
            precision: precision,
            quantization: quantization,
            kvCacheBytesPerToken: kvCacheBytesPerToken,
            estimatedMemoryBytes: estimatedMemoryBytes,
            estimatedQualityScore: estimatedQualityScore,
            estimatedTokensPerSecond: estimatedTokensPerSecond,
            capabilities: capabilities,
            isExperimental: isExperimental
        )
    }

    /// Returns a copy with the developer-validation gate explicitly set.
    public func withExperimental(_ isExperimental: Bool) -> ArchonModelManifest {
        ArchonModelManifest(
            schemaVersion: schemaVersion,
            modelID: modelID,
            modelName: modelName,
            sourceRepository: sourceRepository,
            sourceRevision: sourceRevision,
            license: license,
            logoURL: logoURL,
            runtime: runtime,
            format: format,
            architecture: architecture,
            supportedDeviceArchitectures: supportedDeviceArchitectures,
            artifactPath: artifactPath,
            modelResources: modelResources,
            tokenizerResources: tokenizerResources,
            checksum: checksum,
            modelSizeBytes: modelSizeBytes,
            parameterCount: parameterCount,
            platforms: platforms,
            minimumOS: minimumOS,
            contextLength: contextLength,
            precision: precision,
            quantization: quantization,
            kvCacheBytesPerToken: kvCacheBytesPerToken,
            estimatedMemoryBytes: estimatedMemoryBytes,
            estimatedQualityScore: estimatedQualityScore,
            estimatedTokensPerSecond: estimatedTokensPerSecond,
            capabilities: capabilities,
            isExperimental: isExperimental
        )
    }
}

public struct InstalledModel: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let directoryURL: URL
    public let manifest: ArchonModelManifest
    public let installedAt: Date

    public init(id: String, directoryURL: URL, manifest: ArchonModelManifest, installedAt: Date = Date()) {
        self.id = id
        self.directoryURL = directoryURL
        self.manifest = manifest
        self.installedAt = installedAt
    }

    /// The installed file or directory containing the runnable model artifact.
    /// Older manifests without `artifactPath` fall back to their first non-manifest child.
    public var artifactURL: URL {
        if let artifactPath = manifest.artifactPath {
            return directoryURL.appendingPathComponent(artifactPath)
        }
        let children = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return children.first { $0.lastPathComponent != ArchonModelManifest.filename } ?? directoryURL
    }

    /// Resolves a manifest resource under the installed artifact root.
    public func resourceURL(_ resource: ModelResource) -> URL? {
        let base = artifactURL.standardizedFileURL
        let candidate = base.appendingPathComponent(resource.relativePath).standardizedFileURL
        guard candidate.path != base.path, candidate.path.hasPrefix(base.path + "/") else { return nil }
        return candidate
    }
}

/// A catalog revision newer than the revision recorded for an installed model.
public struct ModelUpdateCandidate: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let installedModelID: String
    public let sourceRepository: String
    public let currentRevision: String
    public let availableRevision: String
    public let variant: ModelVariant?
    public let logoURL: URL?

    public init(
        id: String,
        installedModelID: String,
        sourceRepository: String,
        currentRevision: String,
        availableRevision: String,
        variant: ModelVariant? = nil,
        logoURL: URL? = nil
    ) {
        self.id = id
        self.installedModelID = installedModelID
        self.sourceRepository = sourceRepository
        self.currentRevision = currentRevision
        self.availableRevision = availableRevision
        self.variant = variant
        self.logoURL = logoURL
    }
}

public struct ModelManifestValidationReport: Codable, Equatable, Sendable {
    public let errors: [String]
    public let warnings: [String]

    public init(errors: [String] = [], warnings: [String] = []) {
        self.errors = errors
        self.warnings = warnings
    }

    public var isValid: Bool { errors.isEmpty }
}

/// Validates the metadata and optional local artifact for an Archon model package.
///
/// Validation is deliberately conservative: raw Hugging Face formats remain
/// invalid until a conversion tool emits a directly runnable Archon artifact.
public enum ModelManifestValidator {
    public static func validate(
        _ manifest: ArchonModelManifest,
        artifactAt artifactURL: URL? = nil
    ) -> ModelManifestValidationReport {
        var errors: [String] = []
        var warnings: [String] = []

        if manifest.schemaVersion != ArchonModelManifest.currentSchemaVersion {
            errors.append("Unsupported manifest schema version \(manifest.schemaVersion).")
        }
        if manifest.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("modelID must not be empty.")
        }
        if manifest.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("modelName must not be empty.")
        }
        if manifest.runtime == .unknown {
            errors.append("runtime must identify a concrete execution backend.")
        }
        if manifest.format.requiresConversion {
            errors.append("\(manifest.format.rawValue) requires conversion before it can be packaged.")
        }
        if let expectedRuntime = manifest.format.directRuntime, manifest.runtime != expectedRuntime {
            errors.append("The \(manifest.format.rawValue) artifact must declare the \(expectedRuntime.rawValue) runtime.")
        }
        if manifest.isExperimental {
            warnings.append("This artifact is Experimental until runtime, output, and device validation have passed.")
        }
        if manifest.platforms.isEmpty {
            errors.append("platforms must contain at least one supported platform.")
        }
        if let contextLength = manifest.contextLength, contextLength <= 0 {
            errors.append("contextLength must be greater than zero.")
        }
        if let modelSizeBytes = manifest.modelSizeBytes, modelSizeBytes < 0 {
            errors.append("modelSizeBytes must not be negative.")
        }
        if let estimatedMemoryBytes = manifest.estimatedMemoryBytes, estimatedMemoryBytes < 0 {
            errors.append("estimatedMemoryBytes must not be negative.")
        }
        if let estimatedQualityScore = manifest.estimatedQualityScore,
           !estimatedQualityScore.isFinite || !(0...1).contains(estimatedQualityScore) {
            errors.append("estimatedQualityScore must be a finite value between 0 and 1.")
        }
        if let estimatedTokensPerSecond = manifest.estimatedTokensPerSecond,
           !estimatedTokensPerSecond.isFinite || estimatedTokensPerSecond < 0 {
            errors.append("estimatedTokensPerSecond must be a finite non-negative value.")
        }
        if let checksum = manifest.checksum {
            let isSHA256 = checksum.count == 64 && checksum.allSatisfy { $0.isHexDigit }
            if !isSHA256 {
                errors.append("checksum must be a 64-character SHA-256 hex digest.")
            }
        }

        if let artifactPath = manifest.artifactPath {
            let components = artifactPath.split(separator: "/", omittingEmptySubsequences: false)
            if artifactPath.isEmpty || artifactPath.hasPrefix("/") || components.count != 1 || components.contains(where: { $0 == ".." || $0 == "." }) {
                errors.append("artifactPath must be a single safe relative path component.")
            }
        }

        validateResources(manifest.modelResources, label: "modelResources", errors: &errors)
        validateResources(manifest.tokenizerResources, label: "tokenizerResources", errors: &errors)
        let declaredResources = manifest.modelResources.map { ("modelResources", $0) } + manifest.tokenizerResources.map { ("tokenizerResources", $0) }
        let allResourcePaths = declaredResources.map { $0.1.relativePath }
        if Set(allResourcePaths).count != allResourcePaths.count {
            errors.append("modelResources and tokenizerResources must not share relative paths.")
        }

        if artifactURL == nil && (manifest.modelSizeBytes != nil || manifest.checksum != nil) {
            warnings.append("Artifact size and checksum were not checked because no local artifact was supplied.")
        }

        if let artifactURL {
            let fileManager = FileManager.default
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: artifactURL.path, isDirectory: &isDirectory) else {
                errors.append("Artifact does not exist at \(artifactURL.path).")
                return ModelManifestValidationReport(errors: errors, warnings: warnings)
            }
            if !isDirectory.boolValue {
                if !declaredResources.isEmpty {
                    errors.append("Declared model and tokenizer resources require a directory artifact.")
                }
                do {
                    let attributes = try fileManager.attributesOfItem(atPath: artifactURL.path)
                    if let actualSize = (attributes[.size] as? NSNumber)?.int64Value,
                       let expectedSize = manifest.modelSizeBytes,
                       actualSize != expectedSize {
                        errors.append("Artifact size mismatch: expected \(expectedSize), received \(actualSize).")
                    }
                    if let expectedChecksum = manifest.checksum {
                        let actualChecksum = try sha256(of: artifactURL)
                        if expectedChecksum.lowercased() != actualChecksum {
                            errors.append("Artifact checksum mismatch: expected \(expectedChecksum), received \(actualChecksum).")
                        }
                    }
                } catch {
                    errors.append("Artifact could not be inspected: \(error.localizedDescription).")
                }
            } else {
                let artifactRoot = artifactURL.standardizedFileURL
                if let expectedSize = manifest.modelSizeBytes {
                    do {
                        let actualSize = try directorySize(at: artifactRoot)
                        if actualSize != expectedSize {
                            errors.append("Directory artifact size mismatch: expected \(expectedSize), received \(actualSize).")
                        }
                    } catch {
                        errors.append("Directory artifact size could not be inspected: \(error.localizedDescription).")
                    }
                }
                if let expectedChecksum = manifest.checksum {
                    do {
                        let actualChecksum = try directoryChecksum(at: artifactRoot)
                        if expectedChecksum.lowercased() != actualChecksum {
                            errors.append("Directory artifact checksum mismatch: expected \(expectedChecksum), received \(actualChecksum).")
                        }
                    } catch {
                        errors.append("Directory artifact checksum could not be inspected: \(error.localizedDescription).")
                    }
                }
                if declaredResources.isEmpty {
                    // The aggregate directory size/checksum above covers
                    // bundles that do not enumerate every contained resource.
                } else {
                    for (label, resource) in declaredResources {
                        guard let resourceURL = safeResourceURL(resource.relativePath, relativeTo: artifactRoot) else {
                            errors.append("\(label) contains an unsafe relative path: \(resource.relativePath).")
                            continue
                        }
                        var resourceIsDirectory: ObjCBool = false
                        guard fileManager.fileExists(atPath: resourceURL.path, isDirectory: &resourceIsDirectory) else {
                            errors.append("Missing \(label) resource: \(resource.relativePath).")
                            continue
                        }
                        guard !resourceIsDirectory.boolValue else {
                            errors.append("\(label) resource must be a file: \(resource.relativePath).")
                            continue
                        }
                        do {
                            let attributes = try fileManager.attributesOfItem(atPath: resourceURL.path)
                            if let actualSize = (attributes[.size] as? NSNumber)?.int64Value,
                               let expectedSize = resource.sizeBytes,
                               actualSize != expectedSize {
                                errors.append("Resource size mismatch for \(resource.relativePath): expected \(expectedSize), received \(actualSize).")
                            }
                            if let expectedChecksum = resource.sha256 {
                                let actualChecksum = try sha256(of: resourceURL)
                                if expectedChecksum.lowercased() != actualChecksum {
                                    errors.append("Resource checksum mismatch for \(resource.relativePath): expected \(expectedChecksum), received \(actualChecksum).")
                                }
                            }
                        } catch {
                            errors.append("Resource could not be inspected at \(resource.relativePath): \(error.localizedDescription).")
                        }
                    }
                }
            }
        }

        return ModelManifestValidationReport(errors: errors, warnings: warnings)
    }

    private static func validateResources(
        _ resources: [ModelResource],
        label: String,
        errors: inout [String]
    ) {
        var paths = Set<String>()
        for resource in resources {
            let path = resource.relativePath
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            if path.isEmpty || path.hasPrefix("/") || components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) {
                errors.append("\(label) contains an unsafe relative path: \(path).")
            }
            if resource.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append("\(label) contains a resource with an empty name.")
            }
            if !paths.insert(path).inserted {
                errors.append("\(label) contains duplicate relative path: \(path).")
            }
            if let sizeBytes = resource.sizeBytes, sizeBytes < 0 {
                errors.append("\(label) contains a negative resource size for \(resource.name).")
            }
            if let checksum = resource.sha256,
               !(checksum.count == 64 && checksum.allSatisfy { $0.isHexDigit }) {
                errors.append("\(label) contains an invalid checksum for \(resource.name).")
            }
        }
    }

    private static func sha256(of url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ArchonModelsError.invalidResponse
        }
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func directoryFiles(at directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            throw ArchonModelsError.invalidResponse
        }

        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        var files: [URL] = []
        for case let item as URL in enumerator {
            let attributes = try FileManager.default.attributesOfItem(atPath: item.path)
            if (attributes[.type] as? FileAttributeType) == .typeSymbolicLink {
                throw ArchonModelsError.invalidResponse
            }
            let resolved = item.standardizedFileURL.resolvingSymlinksInPath()
            guard resolved.path == root.path || resolved.path.hasPrefix(root.path + "/") else {
                throw ArchonModelsError.invalidResponse
            }
            let values = try item.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory != true, item.lastPathComponent != ArchonModelManifest.filename {
                files.append(item)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func directorySize(at directory: URL) throws -> Int64 {
        try directoryFiles(at: directory).reduce(into: Int64(0)) { total, file in
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard let size = (attributes[.size] as? NSNumber)?.int64Value, size >= 0 else {
                throw ArchonModelsError.invalidResponse
            }
            let (sum, overflow) = total.addingReportingOverflow(size)
            guard !overflow else { throw ArchonModelsError.invalidResponse }
            total = sum
        }
    }

    /// Computes a stable tree digest from sorted relative paths and file bytes.
    /// The manifest sidecar is intentionally excluded because it describes the
    /// artifact rather than being part of the runnable artifact itself.
    private static func directoryChecksum(at directory: URL) throws -> String {
        let files = try directoryFiles(at: directory)
        let base = directory.standardizedFileURL.path + "/"
        var digest = SHA256()
        for file in files {
            let relative = String(file.standardizedFileURL.path.dropFirst(base.count))
            digest.update(data: Data(relative.utf8))
            digest.update(data: Data([0]))
            guard let handle = try? FileHandle(forReadingFrom: file) else {
                throw ArchonModelsError.invalidResponse
            }
            while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
                digest.update(data: data)
            }
            try? handle.close()
            digest.update(data: Data([0]))
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func safeResourceURL(_ path: String, relativeTo base: URL) -> URL? {
        guard !path.isEmpty, !path.hasPrefix("/") else { return nil }
        let candidate = base.appendingPathComponent(path).standardizedFileURL
        guard candidate.path != base.path, candidate.path.hasPrefix(base.path + "/") else { return nil }
        let resolvedBase = base.resolvingSymlinksInPath().standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedCandidate.path != resolvedBase.path, resolvedCandidate.path.hasPrefix(resolvedBase.path + "/") else { return nil }
        return candidate
    }
}

public enum ArchonModelsError: Error, LocalizedError, Equatable, Sendable {
    case invalidModelIdentifier(String)
    case invalidResponse
    case invalidManifest([String])
    case httpFailure(statusCode: Int)
    case unsupportedArtifact(String)
    case manifestRequired
    case authenticationRequired(String)
    case licenseConfirmationRequired(String)
    case licenseDenied(String)
    case integrityCheckFailed(expected: String, actual: String)
    case sizeMismatch(expected: Int64, actual: Int64)
    case downloadSizeExceeded(maximum: Int64)
    case insufficientDiskSpace
    case backgroundTransferFailed(String)
    case downloadInProgress(String)
    case modelLoadInProgress(String)
    case updateUnavailable(String)
    case noDownloadURL
    case cancelled
    case incompatible(ModelCompatibilityStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidModelIdentifier(let value): "Invalid model identifier: \(value)"
        case .invalidResponse: "The model catalog returned an invalid response."
        case .invalidManifest(let errors): "Invalid Archon model manifest: \(errors.joined(separator: " "))"
        case .httpFailure(let statusCode): "Model service returned HTTP \(statusCode)."
        case .unsupportedArtifact(let value): "Unsupported model artifact: \(value)"
        case .manifestRequired: "A model manifest is required before importing this artifact."
        case .authenticationRequired(let host): "A credential is required before downloading from \(host)."
        case .licenseConfirmationRequired(let identifier): "License confirmation is required before installing \(identifier)."
        case .licenseDenied(let identifier): "The model license is denied by the active policy: \(identifier)."
        case .integrityCheckFailed(let expected, let actual): "Model checksum mismatch. Expected \(expected), received \(actual)."
        case .sizeMismatch(let expected, let actual): "Model size mismatch. Expected \(expected) bytes, received \(actual) bytes."
        case .downloadSizeExceeded(let maximum): "Model download exceeds the configured maximum of \(maximum) bytes."
        case .insufficientDiskSpace: "There is not enough disk space to install this model."
        case .backgroundTransferFailed(let reason): "Background model transfer failed: \(reason)"
        case .downloadInProgress(let id): "A download is already in progress for \(id)."
        case .modelLoadInProgress(let id): "Model loading is already in progress for \(id)."
        case .updateUnavailable(let id): "No downloadable model update is available for \(id)."
        case .noDownloadURL: "This model variant does not provide a download URL."
        case .cancelled: "The model download was cancelled."
        case .incompatible(let status): "The model variant is not compatible with this device: \(status.rawValue)."
        }
    }
}
