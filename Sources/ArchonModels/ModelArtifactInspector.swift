import CryptoKit
import Foundation
import ArchonCore

/// The result of inspecting a user-selected model artifact before it enters the
/// managed library. Raw formats are identified, but remain conversion-required.
public struct ModelArtifactInspection: Codable, Equatable, Sendable {
    public let format: ArchonModelFormat
    public let runtime: ArchonModelRuntime
    public let modelName: String
    public let modelArchitecture: String?
    public let supportedDeviceArchitectures: Set<String>
    public let modelSizeBytes: Int64?
    public let checksum: String?
    public let modelResources: [ModelResource]
    public let tokenizerResources: [ModelResource]
    public let manifest: ArchonModelManifest?

    public init(
        format: ArchonModelFormat,
        runtime: ArchonModelRuntime,
        modelName: String,
        modelArchitecture: String? = nil,
        supportedDeviceArchitectures: Set<String> = [],
        modelSizeBytes: Int64? = nil,
        checksum: String? = nil,
        modelResources: [ModelResource] = [],
        tokenizerResources: [ModelResource] = [],
        manifest: ArchonModelManifest? = nil
    ) {
        self.format = format
        self.runtime = runtime
        self.modelName = modelName
        self.modelArchitecture = modelArchitecture
        self.supportedDeviceArchitectures = supportedDeviceArchitectures
        self.modelSizeBytes = modelSizeBytes
        self.checksum = checksum
        self.modelResources = modelResources
        self.tokenizerResources = tokenizerResources
        self.manifest = manifest
    }

    public var requiresConversion: Bool { format.requiresConversion }
    public var isRunnable: Bool {
        !requiresConversion && runtime != .unknown &&
            (format.directRuntime == nil || format.directRuntime == runtime) &&
            !(manifest?.isExperimental ?? false)
    }

    /// Creates a manifest for an artifact that has no sidecar manifest. The
    /// caller still must validate the resulting manifest against the artifact.
    public func makeManifest(
        modelID: String,
        sourceRepository: String? = nil,
        sourceRevision: String? = nil,
        license: ModelLicenseMetadata? = nil,
        logoURL: URL? = nil,
        isExperimental: Bool = false
    ) -> ArchonModelManifest {
        if let manifest { return manifest }
        let estimatedMemory = modelSizeBytes.map { Int64(Double($0) * 1.15) }
        return ArchonModelManifest(
            modelID: modelID,
            modelName: modelName,
            sourceRepository: sourceRepository,
            sourceRevision: sourceRevision,
            license: license,
            logoURL: logoURL,
            runtime: runtime,
            format: format,
            architecture: modelArchitecture,
            supportedDeviceArchitectures: supportedDeviceArchitectures,
            modelResources: modelResources,
            tokenizerResources: tokenizerResources,
            checksum: checksum,
            modelSizeBytes: modelSizeBytes,
            estimatedMemoryBytes: estimatedMemory,
            isExperimental: isExperimental
        )
    }
}

/// Detects the representation of a local file or model package without
/// claiming that arbitrary weights can execute on Apple platforms.
public enum ModelArtifactInspector {
    public static func inspect(at url: URL) throws -> ModelArtifactInspection {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ArchonModelsError.unsupportedArtifact("No model artifact exists at \(url.path).")
        }

        let name = url.deletingPathExtension().lastPathComponent.isEmpty
            ? url.lastPathComponent
            : url.deletingPathExtension().lastPathComponent

        if isDirectory.boolValue {
            if let manifestData = try? Data(contentsOf: url.appendingPathComponent(ArchonModelManifest.filename)),
               let manifest = try? JSONDecoder().decode(ArchonModelManifest.self, from: manifestData) {
                return ModelArtifactInspection(
                    format: manifest.format,
                    runtime: manifest.runtime,
                    modelName: manifest.modelName,
                    modelArchitecture: manifest.architecture,
                    supportedDeviceArchitectures: manifest.supportedDeviceArchitectures,
                    modelSizeBytes: manifest.modelSizeBytes,
                    checksum: manifest.checksum,
                    modelResources: manifest.modelResources,
                    tokenizerResources: manifest.tokenizerResources,
                    manifest: manifest
                )
            }

            let files = try regularFiles(in: url)
            let relativeFiles = try files.map { file -> ModelResource in
                let relativePath = try relativePath(of: file, relativeTo: url)
                let dataSize = try fileSize(of: file)
                return ModelResource(
                    name: file.lastPathComponent,
                    relativePath: relativePath,
                    sizeBytes: dataSize,
                    sha256: try sha256(of: file)
                )
            }
            let totalSize = relativeFiles.compactMap(\.sizeBytes).reduceIfAllValuesPresent()
            let lowercasedExtension = url.pathExtension.lowercased()
            if ["aimodel", "coreai", "coreaibundle", "bundle"].contains(lowercasedExtension) {
                return ModelArtifactInspection(
                    format: .coreAIBundle,
                    runtime: .coreAI,
                    modelName: name,
                    supportedDeviceArchitectures: ["arm64"],
                    modelSizeBytes: totalSize,
                    modelResources: relativeFiles
                )
            }

            let filenames = Set(files.map { $0.lastPathComponent.lowercased() })
            let hasWeights = files.contains { isModelWeightFile($0) }
            let hasConfiguration = filenames.contains("config.json")
            let hasTokenizer = filenames.contains("tokenizer.json") ||
                filenames.contains("tokenizer.model") ||
                (filenames.contains("vocab.json") && filenames.contains("merges.txt"))
            if hasWeights && hasConfiguration && hasTokenizer {
                let architecture = try modelArchitecture(from: url.appendingPathComponent("config.json"))
                let tokenizer = relativeFiles.filter { isTokenizerResource($0.relativePath) }
                let weights = relativeFiles.filter { !isTokenizerResource($0.relativePath) }
                let isMLX = isLikelyMLXDirectory(at: url)
                return ModelArtifactInspection(
                    format: isMLX ? .mlx : .transformers,
                    runtime: isMLX ? .mlx : .unknown,
                    modelName: name,
                    modelArchitecture: architecture,
                    supportedDeviceArchitectures: isMLX ? ["arm64"] : [],
                    modelSizeBytes: totalSize,
                    modelResources: weights,
                    tokenizerResources: tokenizer
                )
            }

            return ModelArtifactInspection(
                format: .unknown,
                runtime: .unknown,
                modelName: name,
                modelSizeBytes: totalSize,
                modelResources: relativeFiles
            )
        }

        let format: ArchonModelFormat
        let runtime: ArchonModelRuntime
        switch url.pathExtension.lowercased() {
        case "aimodel":
            format = .aimodel
            runtime = .coreAI
        case "gguf":
            format = .gguf
            runtime = .unknown
        case "safetensors":
            format = .safetensors
            runtime = .unknown
        case "bin", "pt", "pth", "ckpt":
            format = .transformers
            runtime = .unknown
        default:
            format = .unknown
            runtime = .unknown
        }
        return ModelArtifactInspection(
            format: format,
            runtime: runtime,
            modelName: name,
            supportedDeviceArchitectures: runtime == .coreAI ? ["arm64"] : [],
            modelSizeBytes: try fileSize(of: url),
            checksum: try sha256(of: url)
        )
    }

    private static func regularFiles(in directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { throw ArchonModelsError.unsupportedArtifact("Unable to enumerate \(directory.path).") }

        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        var files: [URL] = []
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                throw ArchonModelsError.unsupportedArtifact("Symbolic links are not accepted in imported model packages.")
            }
            let resolved = item.standardizedFileURL.resolvingSymlinksInPath()
            guard resolved.path == root.path || resolved.path.hasPrefix(root.path + "/") else {
                throw ArchonModelsError.unsupportedArtifact("Model package escapes its selected directory.")
            }
            if values.isDirectory != true { files.append(item) }
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func relativePath(of file: URL, relativeTo root: URL) throws -> String {
        let base = root.standardizedFileURL.path + "/"
        let path = file.standardizedFileURL.path
        guard path.hasPrefix(base) else {
            throw ArchonModelsError.unsupportedArtifact("Model resource escapes its selected directory.")
        }
        let relative = String(path.dropFirst(base.count))
        guard !relative.isEmpty,
              !relative.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw ArchonModelsError.unsupportedArtifact("Model package contains an unsafe resource path.")
        }
        return relative
    }

    private static func fileSize(of url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let value = (attributes[.size] as? NSNumber)?.int64Value else {
            throw ArchonModelsError.unsupportedArtifact("Unable to inspect \(url.lastPathComponent).")
        }
        return value
    }

    private static func sha256(of url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ArchonModelsError.unsupportedArtifact("Unable to hash \(url.lastPathComponent).")
        }
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func modelArchitecture(from configURL: URL) throws -> String? {
        let data = try Data(contentsOf: configURL)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let architectures = object["architectures"] as? [String], let first = architectures.first { return first }
        return object["model_type"] as? String
    }

    private static func isTokenizerResource(_ path: String) -> Bool {
        let lowercased = path.lowercased()
        return lowercased.hasSuffix("tokenizer.json") ||
            lowercased.hasSuffix("tokenizer.model") ||
            lowercased.hasSuffix("vocab.json") ||
            lowercased.hasSuffix("merges.txt") ||
            lowercased.hasSuffix("special_tokens_map.json") ||
            lowercased.hasSuffix("tokenizer_config.json")
    }

    private static func isModelWeightFile(_ url: URL) -> Bool {
        ["safetensors", "bin", "pt", "pth", "ckpt"].contains(url.pathExtension.lowercased())
    }

    /// MLX-LM's on-disk contract includes a top-level quantization object in
    /// quantized exports. A generic Transformers directory often has the same
    /// weights/config/tokenizer filenames, so it remains conversion-required
    /// unless this runtime-specific marker or an explicit `.mlx` package name
    /// is present.
    private static func isLikelyMLXDirectory(at url: URL) -> Bool {
        let lowercasedName = url.lastPathComponent.lowercased()
        if lowercasedName.hasSuffix(".mlx") {
            return true
        }

        guard let data = try? Data(contentsOf: url.appendingPathComponent("config.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let quantization = object["quantization"] as? [String: Any],
              let bits = quantization["bits"] as? NSNumber,
              let groupSize = quantization["group_size"] as? NSNumber else {
            return false
        }
        return bits.intValue > 0 && groupSize.intValue > 0
    }
}

private extension Array where Element == Int64 {
    func reduceIfAllValuesPresent() -> Int64? {
        isEmpty ? nil : reduce(0, +)
    }
}
