import Foundation
import ArchonModels

#if canImport(CoreAI)
import CoreAI
#endif

/// A stable, Archon-owned description of a function exported by a Core AI asset.
public struct CoreAIModelFunctionDescriptor: Sendable, Equatable, Codable {
    public let name: String
    public let inputNames: [String]
    public let stateNames: [String]
    public let outputNames: [String]

    public init(
        name: String,
        inputNames: [String],
        stateNames: [String],
        outputNames: [String]
    ) {
        self.name = name
        self.inputNames = inputNames
        self.stateNames = stateNames
        self.outputNames = outputNames
    }
}

/// Metadata exposed by a validated Core AI asset without leaking framework-only types.
public struct CoreAIModelMetadata: Sendable, Equatable, Codable {
    public let author: String
    public let license: String
    public let description: String
    public let creationDate: Date?

    public init(
        author: String,
        license: String,
        description: String,
        creationDate: Date?
    ) {
        self.author = author
        self.license = license
        self.description = description
        self.creationDate = creationDate
    }
}

/// Evidence collected from the public Core AI asset and runtime APIs.
public struct CoreAIModelInspection: Sendable, Equatable, Codable {
    public let sourceIdentifier: String
    public let resolvedURL: URL
    public let metadata: CoreAIModelMetadata
    public let functions: [CoreAIModelFunctionDescriptor]
    public let loadedFunctionNames: [String]

    public init(
        sourceIdentifier: String,
        resolvedURL: URL,
        metadata: CoreAIModelMetadata,
        functions: [CoreAIModelFunctionDescriptor],
        loadedFunctionNames: [String] = []
    ) {
        self.sourceIdentifier = sourceIdentifier
        self.resolvedURL = resolvedURL
        self.metadata = metadata
        self.functions = functions
        self.loadedFunctionNames = loadedFunctionNames
    }
}

/// Actor-isolated bridge over Apple's public Core AI asset and runtime APIs.
///
/// The bridge deliberately keeps `AIModel` inside the actor. Applications that
/// need text generation can use `loadFunction` from a model-specific adapter,
/// alongside the tokenizer and input/output contract for that asset.
public actor CoreAIModelRuntime {
    #if canImport(CoreAI)
    private var loadedModels: [String: AIModel] = [:]
    #endif

    public init() {}

    /// Whether this build and runtime can use Apple's public Core AI framework.
    public nonisolated var isAvailable: Bool {
        #if canImport(CoreAI)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            return true
        }
        #endif
        return false
    }

    /// Inspects a bundled or local asset using `AIModelAsset`.
    public func inspect(source: CoreAIModelSource) throws -> CoreAIModelInspection {
        #if canImport(CoreAI)
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) else {
            throw CoreAIProviderError.runtimeUnavailable("Core AI requires iOS 27, macOS 27, or visionOS 27.")
        }

        let url = try resolveURL(for: source)
        guard AIModelAsset.isValid(at: url) else {
            throw CoreAIProviderError.invalidModelAsset(url.path)
        }

        let asset: AIModelAsset
        do {
            asset = try AIModelAsset(contentsOf: url)
        } catch {
            throw CoreAIProviderError.compilationFailed(String(describing: error))
        }

        let summary: AIModelAsset.Summary?
        do {
            summary = try asset.summary(includingStatistics: false)
        } catch {
            throw CoreAIProviderError.compilationFailed(String(describing: error))
        }

        let metadata = CoreAIModelMetadata(
            author: asset.metadata.author,
            license: asset.metadata.license,
            description: asset.metadata.description,
            creationDate: asset.metadata.creationDate
        )
        let functions = (summary?.functions ?? []).map { function in
            CoreAIModelFunctionDescriptor(
                name: function.name,
                inputNames: function.inputs.map(\.name),
                stateNames: function.states.map(\.name),
                outputNames: function.outputs.map(\.name)
            )
        }

        return CoreAIModelInspection(
            sourceIdentifier: source.identifier,
            resolvedURL: url,
            metadata: metadata,
            functions: functions
        )
        #else
        throw CoreAIProviderError.runtimeUnavailable("This build was compiled without the public Core AI framework.")
        #endif
    }

    /// Specializes and caches an asset with the requested public Core AI compute unit.
    @discardableResult
    public func prepare(
        source: CoreAIModelSource,
        computeUnit: CoreAIComputeUnit
    ) async throws -> CoreAIModelInspection {
        #if canImport(CoreAI)
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) else {
            throw CoreAIProviderError.runtimeUnavailable("Core AI requires iOS 27, macOS 27, or visionOS 27.")
        }

        let inspection = try inspect(source: source)
        let options = SpecializationOptions(
            preferredComputeUnitKind: computeUnit.coreAIKind
        )
        do {
            loadedModels[inspection.sourceIdentifier] = try await AIModel(
                contentsOf: inspection.resolvedURL,
                options: options
            )
        } catch {
            throw CoreAIProviderError.compilationFailed(String(describing: error))
        }

        let loadedFunctionNames = loadedModels[inspection.sourceIdentifier]?.functionNames ?? []
        return CoreAIModelInspection(
            sourceIdentifier: inspection.sourceIdentifier,
            resolvedURL: inspection.resolvedURL,
            metadata: inspection.metadata,
            functions: inspection.functions,
            loadedFunctionNames: loadedFunctionNames
        )
        #else
        throw CoreAIProviderError.runtimeUnavailable("This build was compiled without the public Core AI framework.")
        #endif
    }

    #if canImport(CoreAI)
    /// Loads one exported function for an application-owned model adapter.
    @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
    public func loadFunction(
        named name: String,
        source: CoreAIModelSource,
        computeUnit: CoreAIComputeUnit
    ) async throws -> InferenceFunction {
        let inspection = try await prepare(source: source, computeUnit: computeUnit)
        guard let model = loadedModels[inspection.sourceIdentifier] else {
            throw CoreAIProviderError.runtimeUnavailable("The Core AI model was not retained after specialization.")
        }
        guard let function = try model.loadFunction(named: name) else {
            throw CoreAIProviderError.functionNotFound(name)
        }
        return function
    }
    #endif

    /// Drops a cached specialized model so memory pressure can be handled by the host.
    public func unload(source: CoreAIModelSource) {
        #if canImport(CoreAI)
        loadedModels.removeValue(forKey: source.identifier)
        #endif
    }

    #if canImport(CoreAI)
    private func resolveURL(for source: CoreAIModelSource) throws -> URL {
        switch source {
        case .localDirectory(let url):
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw CoreAIProviderError.modelNotFound(url.path)
            }
            return url
        case .bundledAsset(let name):
            let candidates = [
                Bundle.main.url(forResource: name, withExtension: nil),
                Bundle.main.url(forResource: name, withExtension: "coreai")
            ]
            guard let url = candidates.compactMap({ $0 }).first else {
                throw CoreAIProviderError.modelNotFound(name)
            }
            return url
        case .modelIdentifier(let identifier):
            throw CoreAIProviderError.sourceUnsupported(
                "The public Core AI API loads URL-backed assets; resolve model identifier '\(identifier)' to a local or bundled asset first."
            )
        }
    }
    #endif
}

/// A concrete `ModelRuntimeAdapter` for installed Archon Core AI packages.
///
/// `ArchonModels` owns compatibility and lifecycle state while this adapter
/// supplies the public Core AI specialization call. Text generation remains a
/// separate model-specific concern handled by `CoreAITextGenerationAdapter`.
public actor CoreAIModelRuntimeAdapter: ModelRuntimeAdapter {
    private let runtime: CoreAIModelRuntime
    private let computeUnit: CoreAIComputeUnit

    public init(
        runtime: CoreAIModelRuntime = CoreAIModelRuntime(),
        computeUnit: CoreAIComputeUnit = .neuralEngineFirst
    ) {
        self.runtime = runtime
        self.computeUnit = computeUnit
    }

    public func load(model: InstalledModel) async throws {
        guard model.manifest.runtime == .coreAI, model.manifest.format == .aimodel else {
            throw ArchonModelsError.unsupportedArtifact(
                "Only installed Core AI artifacts can be loaded by CoreAIModelRuntimeAdapter."
            )
        }
        _ = try await runtime.prepare(
            source: .localDirectory(model.artifactURL),
            computeUnit: computeUnit
        )
    }

    public func unload(model: InstalledModel) async {
        await runtime.unload(source: .localDirectory(model.artifactURL))
    }
}

private extension CoreAIComputeUnit {
    #if canImport(CoreAI)
    @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
    var coreAIKind: ComputeUnitKind {
        switch self {
        case .neuralEngineFirst:
            return .neuralEngine
        case .gpuFirst:
            return .gpu
        case .all:
            return .gpu
        }
    }
    #endif
}
