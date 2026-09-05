import ArgumentParser
import ArchonCore
import ArchonAgent
import ArchonModels
import Foundation

@main
struct ArchonModelCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "archon-model",
        abstract: "Inspect, validate, package, search, and download Archon model artifacts.",
        subcommands: [
            Inspect.self,
            Validate.self,
            Package.self,
            Search.self,
            Download.self,
            Convert.self,
            Benchmark.self
        ]
    )
}

private struct Inspect: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print a model manifest as normalized JSON.")

    @Argument(help: "Path to archon-model.json.")
    var manifestPath: String

    mutating func run() throws {
        let manifest = try readManifest(at: manifestPath)
        print(try encodeJSON(manifest))
    }
}

private struct Validate: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Validate a manifest and an optional local artifact.")

    @Argument(help: "Path to archon-model.json.")
    var manifestPath: String

    @Option(name: .long, help: "Optional artifact file or directory to hash and size-check.")
    var artifact: String?

    @Flag(name: .long, help: "Emit a stable machine-readable JSON report.")
    var json = false

    mutating func run() throws {
        let manifest = try readManifest(at: manifestPath)
        let report = ModelManifestValidator.validate(
            manifest,
            artifactAt: artifact.map(localURL)
        )
        if json {
            let payload: [String: Any] = [
                "valid": report.isValid,
                "warnings": report.warnings,
                "errors": report.errors
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } else {
            print("valid: \(report.isValid)")
            for warning in report.warnings {
                print("warning: \(warning)")
            }
            for error in report.errors {
                print("error: \(error)")
            }
        }
        guard report.isValid else {
            throw ValidationError("Manifest validation failed.")
        }
    }
}

private struct Package: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create a directory package containing a validated artifact, resources, and manifest.")

    @Option(name: .long, help: "Path to archon-model.json.")
    var manifest: String

    @Option(name: .long, help: "Path to the directly runnable artifact file or directory; declared resources are resolved inside it.")
    var artifact: String

    @Option(name: .long, help: "Output package directory. It must not already exist.")
    var output: String

    mutating func run() throws {
        let manifestValue = try readManifest(at: manifest)
        let artifactURL = localURL(artifact)
        let artifactName = safeArtifactName(artifactURL.lastPathComponent)
        let packagedManifest = manifestValue.withArtifactPath(artifactName)
        let report = ModelManifestValidator.validate(packagedManifest, artifactAt: artifactURL)
        guard report.isValid else {
            throw ValidationError(report.errors.joined(separator: " "))
        }

        let fileManager = FileManager.default
        let outputURL = localURL(output)
        guard !fileManager.fileExists(atPath: outputURL.path) else {
            throw ValidationError("Output already exists: \(outputURL.path)")
        }
        try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)
        do {
            let destinationArtifact = outputURL.appendingPathComponent(artifactName)
            try fileManager.copyItem(at: artifactURL, to: destinationArtifact)
            try encodeJSON(packagedManifest).write(
                to: outputURL.appendingPathComponent(ArchonModelManifest.filename),
                options: .atomic
            )
        } catch {
            try? fileManager.removeItem(at: outputURL)
            throw error
        }
        print("packaged: \(outputURL.path)")
    }
}

private struct Search: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Search Hugging Face model metadata.")

    @Argument(help: "Search text or repository name.")
    var query: String = ""

    @Option(name: .long, help: "Maximum number of repositories to return.")
    var limit: Int = 20

    @Flag(name: .long, help: "Only return variants compatible with this Mac.")
    var compatibleOnly = false

    @Flag(name: .long, help: "Search only local manifests; never access the network.")
    var offline = false

    @Option(name: .long, help: "Local manifest directory used with --offline.")
    var localPath: String?

    mutating func run() async throws {
        let catalog: any ModelCatalogProvider
        if offline {
            let path: String
            if let localPath {
                path = localPath
            } else {
                let library = ModelLibrary.makeDefault()
                path = await library.rootURL.path
            }
            catalog = LocalModelCatalog(locations: [localURL(path)])
        } else {
            catalog = HuggingFaceCatalog()
        }
        let models = try await catalog.search(ModelSearchRequest(
            query: query,
            compatibleOnly: compatibleOnly,
            device: compatibleOnly ? ArchonDeviceCapabilities.current : nil,
            limit: limit
        ))
        for model in models {
            let variants = model.variants.map { "\($0.name):\($0.format.rawValue)" }.joined(separator: ", ")
            print("\(model.id)\t\(variants)")
        }
    }
}

private struct Download: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Download a directly runnable Hugging Face artifact into the Archon model library.")

    @Argument(help: "Hugging Face repository identifier, for example Qwen/Qwen3.")
    var repository: String

    @Option(name: .long, help: "Exact variant ID. Defaults to the first directly runnable variant.")
    var variantID: String?

    mutating func run() async throws {
        let catalog = HuggingFaceCatalog()
        let descriptor = try await catalog.inspect(repositoryID: repository)
        guard let variant = descriptor.variants.first(where: {
            if let variantID { return $0.id == variantID }
            return !$0.format.requiresConversion
        }) else {
            throw ValidationError("No directly runnable variant was found. Raw Hugging Face weights require conversion first.")
        }
        guard variant.downloadURL != nil else {
            throw ValidationError("The selected variant has no download URL.")
        }
        let tokenStore = KeychainModelTokenStore()
        let token = await tokenStore.token(for: "huggingface.co")
        if variant.requiresAuthentication && token == nil {
            throw ValidationError("This repository requires a Hugging Face token in the Keychain.")
        }

        let request = ModelDownloadRequest(
            variant: variant,
            modelName: descriptor.name,
            license: descriptor.license,
            sourceRepository: descriptor.id,
            sourceRevision: descriptor.revision
        )
        let library = ModelLibrary.makeDefault()
        let manager = ModelDownloadManager(tokenStore: tokenStore)
        let events = try await manager.download(request, into: library)
        for try await event in events {
            print("\(event.variantID): \(event.state)")
        }
    }
}

private struct Convert: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Convert a supported Hugging Face model through Apple's Core AI export tooling.")

    @Argument(help: "Hugging Face model identifier or short name supported by apple/coreai-models.")
    var input: String

    @Option(name: .long, help: "Destination .aimodel bundle path. Defaults to the current directory.")
    var output: String?

    @Option(name: .long, help: "Path to an Apple coreai-models checkout. Defaults to the current directory.")
    var coreAIModels: String?

    @Option(name: .long, help: "Target export platform, for example macOS or iOS.")
    var platform = "macOS"

    @Option(name: .long, help: "Apple Core AI compression preset, when supported by the selected model.")
    var compression: String?

    @Option(name: .long, help: "Maximum context length for the exported model.")
    var maxContextLength: Int?

    @Flag(name: .long, help: "Use Apple's experimental export path for models without a registry preset.")
    var experimental = false

    mutating func run() throws {
        let fileManager = FileManager.default
        guard let uvURL = executableURL(named: "uv") else {
            throw ValidationError(
                "Apple Core AI conversion requires the developer-side 'uv' tool and the apple/coreai-models checkout; neither is bundled in the runtime package."
            )
        }

        let workingDirectory = localURL(coreAIModels ?? ".")
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: workingDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ValidationError("The --coreai-models path is not an existing directory: \(workingDirectory.path)")
        }

        let destination = localURL(output ?? "\(safeArtifactName(input))-\(safeArtifactName(platform)).aimodel")
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw ValidationError("Destination already exists: \(destination.path)")
        }

        let scratchRoot = destination.deletingLastPathComponent()
            .appendingPathComponent(".archon-convert-\(UUID().uuidString)", isDirectory: true)
        let outputName = safeArtifactName(destination.deletingPathExtension().lastPathComponent)
        try fileManager.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratchRoot) }

        var arguments = [
            "run",
            "coreai.llm.export",
            input,
            "--platform",
            platform,
            "--output-dir",
            scratchRoot.path,
            "--output-name",
            outputName
        ]
        if let compression {
            arguments += ["--compression", compression]
        }
        if let maxContextLength {
            guard maxContextLength > 0 else {
                throw ValidationError("--max-context-length must be greater than zero.")
            }
            arguments += ["--max-context-length", String(maxContextLength)]
        }
        if experimental {
            arguments.append("--experimental")
        }

        let process = Process()
        process.executableURL = uvURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        let diagnosticURL = scratchRoot.appendingPathComponent("export.log")
        guard fileManager.createFile(atPath: diagnosticURL.path, contents: nil) else {
            throw ValidationError("Unable to create a temporary conversion diagnostic file.")
        }
        let diagnosticHandle: FileHandle
        do {
            diagnosticHandle = try FileHandle(forWritingTo: diagnosticURL)
        } catch {
            throw ValidationError("Unable to open a temporary conversion diagnostic file: \(error.localizedDescription)")
        }
        process.standardOutput = diagnosticHandle
        process.standardError = diagnosticHandle
        do {
            try process.run()
        } catch {
            try? diagnosticHandle.close()
            throw ValidationError("Unable to launch Apple's Core AI exporter: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        try? diagnosticHandle.close()
        let exporterOutput = (try? Data(contentsOf: diagnosticURL)) ?? Data()
        let diagnostic = String(data: exporterOutput, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            let detail = diagnostic.isEmpty ? "The exporter exited with status \(process.terminationStatus)." : diagnostic
            throw ValidationError("Apple Core AI conversion failed: \(detail.suffix(4000))")
        }

        guard let artifact = findAimodelArtifact(in: scratchRoot) else {
            throw ValidationError("Apple Core AI conversion completed without producing a .aimodel artifact.")
        }

        if experimental {
            let inspection = try ModelArtifactInspector.inspect(at: artifact)
            let manifest = inspection
                .makeManifest(
                    modelID: input,
                    sourceRepository: input,
                    isExperimental: true
                )
                .withExperimental(true)
            let report = ModelManifestValidator.validate(manifest, artifactAt: artifact)
            guard report.isValid else {
                throw ValidationError("Experimental Core AI conversion produced an invalid manifest: \(report.errors.joined(separator: " "))")
            }
            let manifestURL = artifact.appendingPathComponent(ArchonModelManifest.filename)
            guard !fileManager.fileExists(atPath: manifestURL.path) else {
                throw ValidationError("The exporter already produced an Archon manifest; refusing to overwrite it.")
            }
            try encodeJSON(manifest).write(to: manifestURL, options: .atomic)
        }

        try fileManager.moveItem(at: artifact, to: destination)
        if experimental {
            print("status: Experimental")
        }
        print("converted: \(destination.path)")
    }
}

private struct Benchmark: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Benchmark real runtime model preparation.")

    @Argument(help: "Path to archon-model.json.")
    var manifestPath: String

    @Option(name: .long, help: "Optional path to the runnable artifact. Defaults to the manifest's artifactPath relative to the manifest.")
    var artifact: String?

    @Option(name: .long, help: "Number of measured preparation samples.")
    var iterations: Int = 3

    @Option(name: .long, help: "Number of unreported warmup preparations.")
    var warmupIterations: Int = 1

    mutating func run() async throws {
        let manifestURL = localURL(manifestPath)
        let manifest = try readManifest(at: manifestPath)
        let artifactURL = try resolveArtifact(
            manifest: manifest,
            manifestURL: manifestURL,
            override: artifact
        )
        let validation = ModelManifestValidator.validate(manifest, artifactAt: artifactURL)
        guard validation.isValid else {
            throw ValidationError(validation.errors.joined(separator: " "))
        }

        let adapter: any ModelPreparationBenchmarkAdapter
        switch (manifest.runtime, manifest.format) {
        case (.coreAI, .aimodel), (.coreAI, .coreAIBundle):
            adapter = CoreAIPreparationAdapter(artifactURL: artifactURL)
        case (.mlx, .mlx):
            adapter = MLXPreparationAdapter(artifactURL: artifactURL)
        default:
            throw ValidationError(
                "No concrete preparation benchmark adapter exists for runtime \(manifest.runtime.rawValue) and format \(manifest.format.rawValue)."
            )
        }

        let report = try await ModelPreparationBenchmarkRunner().run(
            adapter: adapter,
            configuration: ModelPreparationBenchmarkConfiguration(
                iterations: iterations,
                warmupIterations: warmupIterations
            )
        )
        let data = try encodeJSON(report)
        print(String(data: data, encoding: .utf8) ?? "{}")
    }
}

private struct CoreAIPreparationAdapter: ModelPreparationBenchmarkAdapter {
    let runtimeName = "Core AI"
    let artifactIdentifier: String
    private let artifactURL: URL
    private let runtime = CoreAIModelRuntime()

    init(artifactURL: URL) {
        self.artifactURL = artifactURL
        self.artifactIdentifier = artifactURL.path
    }

    func prepare() async throws {
        _ = try await runtime.prepare(
            source: .localDirectory(artifactURL),
            computeUnit: .neuralEngineFirst
        )
    }

    func unload() async {
        await runtime.unload(source: .localDirectory(artifactURL))
    }
}

private struct MLXPreparationAdapter: ModelPreparationBenchmarkAdapter {
    let runtimeName = "MLX Swift"
    let artifactIdentifier: String
    private let provider: MLXLocalProvider

    init(artifactURL: URL) {
        self.artifactIdentifier = artifactURL.path
        self.provider = MLXLocalProvider(localModelDirectory: artifactURL)
    }

    func prepare() async throws {
        try await provider.prepare()
    }

    func unload() async {
        await provider.unload()
    }
}

private func localURL(_ path: String) -> URL {
    URL(
        fileURLWithPath: path,
        relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    ).standardizedFileURL
}

private func safeArtifactName(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
    let result = String(scalars.prefix(160))
    return result.isEmpty ? "model" : result
}

private func executableURL(named name: String) -> URL? {
    let fileManager = FileManager.default
    let pathEntries = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":") ?? []
    for entry in pathEntries {
        let candidate = URL(fileURLWithPath: String(entry), isDirectory: true)
            .appendingPathComponent(name)
        if fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
    }
    return nil
}

private func findAimodelArtifact(in root: URL) -> URL? {
    let fileManager = FileManager.default
    guard let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles]
    ) else {
        return nil
    }

    for case let url as URL in enumerator {
        guard url.pathExtension == "aimodel" else { continue }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
        return url
    }
    return nil
}

private func readManifest(at path: String) throws -> ArchonModelManifest {
    let data = try Data(contentsOf: localURL(path))
    return try JSONDecoder().decode(ArchonModelManifest.self, from: data)
}

private func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(value)
}

private func resolveArtifact(
    manifest: ArchonModelManifest,
    manifestURL: URL,
    override: String?
) throws -> URL {
    if let override {
        return localURL(override)
    }
    guard let artifactPath = manifest.artifactPath, !artifactPath.isEmpty else {
        throw ValidationError("Pass --artifact when the manifest does not declare artifactPath.")
    }
    let base = manifestURL.deletingLastPathComponent().standardizedFileURL
    let candidate = base.appendingPathComponent(artifactPath).standardizedFileURL
    guard candidate.path.hasPrefix(base.path + "/") else {
        throw ValidationError("The manifest artifactPath escapes the manifest directory.")
    }
    return candidate
}
