import Foundation
import ArchonCore

public protocol ModelTokenStore: Sendable {
    func token(for service: String) async -> String?
    func setToken(_ token: String?, for service: String) async throws
}

public protocol ModelHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: ModelHTTPClient {}

/// Keychain-backed token storage for Hugging Face or developer registries.
public struct KeychainModelTokenStore: ModelTokenStore, Sendable {
    public let accessGroup: String?

    public init(accessGroup: String? = nil) {
        self.accessGroup = accessGroup
    }

    public func token(for service: String) async -> String? {
        #if canImport(Security)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
        #else
        return nil
        #endif
    }

    public func setToken(_ token: String?, for service: String) async throws {
        #if canImport(Security)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(baseQuery as CFDictionary)
        guard let token else { return }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = Data(token.utf8)
        if let accessGroup { addQuery[kSecAttrAccessGroup as String] = accessGroup }
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ArchonModelsError.invalidResponse
        }
        #else
        _ = token
        _ = service
        throw ArchonModelsError.invalidResponse
        #endif
    }
}

public struct HuggingFaceCatalog: ModelCatalogProvider, Sendable {
    public let id: String = "huggingface"
    public let baseURL: URL
    public let session: any ModelHTTPClient
    public let tokenStore: (any ModelTokenStore)?

    public init(
        baseURL: URL = URL(string: "https://huggingface.co")!,
        session: any ModelHTTPClient = URLSession.shared,
        tokenStore: (any ModelTokenStore)? = KeychainModelTokenStore()
    ) {
        self.baseURL = baseURL
        self.session = session
        self.tokenStore = tokenStore
    }

    public func search(_ request: ModelSearchRequest) async throws -> [ModelDescriptor] {
        if let repositoryID = Self.repositoryID(from: request.query) {
            let model = try await inspect(repositoryID: repositoryID)
            guard let filteredModel = filtered(model, for: request) else {
                return []
            }
            return [filteredModel]
        }
        var components = URLComponents(url: baseURL.appendingPathComponent("api/models"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "search", value: request.query),
            URLQueryItem(name: "limit", value: String(request.limit)),
            // Variant-level filters need the repository file inventory even
            // when the caller only wants compact result rows.
            URLQueryItem(
                name: "full",
                value: (request.includeVariants || request.compatibleOnly || request.runtime != nil || request.format != nil) ? "true" : "false"
            ),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1")
        ]
        guard let url = components?.url else { throw ArchonModelsError.invalidResponse }
        let data = try await data(for: url)
        let summaries = try JSONDecoder().decode([HuggingFaceModelPayload].self, from: data)

        var models: [ModelDescriptor] = []
        for payload in summaries.prefix(request.limit) {
            let model = makeDescriptor(from: payload, includeVariants: true)
            guard let filteredModel = filtered(model, for: request) else { continue }
            models.append(filteredModel)
        }
        return models
    }

    /// Fetches a single repository's complete metadata and artifact inventory.
    public func inspect(repositoryID: String, revision: String? = nil) async throws -> ModelDescriptor {
        guard repositoryID.isEmpty == false, repositoryID.contains("..") == false else {
            throw ArchonModelsError.invalidModelIdentifier(repositoryID)
        }
        var url = baseURL.appendingPathComponent("api/models").appendingPathComponent(repositoryID)
        if let revision {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "revision", value: revision)]
            guard let revisedURL = components?.url else { throw ArchonModelsError.invalidResponse }
            url = revisedURL
        }
        let data = try await data(for: url)
        let payload = try JSONDecoder().decode(HuggingFaceModelPayload.self, from: data)
        return makeDescriptor(from: payload, includeVariants: true)
    }

    private func data(for url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = await tokenStore?.token(for: "huggingface.co") {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ArchonModelsError.invalidResponse }
        guard (200...299).contains(response.statusCode) else {
            throw ArchonModelsError.httpFailure(statusCode: response.statusCode)
        }
        return data
    }

    private func makeDescriptor(from payload: HuggingFaceModelPayload, includeVariants: Bool) -> ModelDescriptor {
        let repositoryID = payload.id
        let publisher = payload.author ?? repositoryID.split(separator: "/").first.map(String.init) ?? "Unknown"
        let tasks = Set([task(for: payload.pipelineTag)])
        let variants = includeVariants ? makeVariants(from: payload) : []
        return ModelDescriptor(
            id: repositoryID,
            name: repositoryID.split(separator: "/").last.map(String.init) ?? repositoryID,
            publisher: publisher,
            family: payload.tags?.first(where: { $0.lowercased().contains("model") == false }),
            parameterCount: parameterCount(from: payload.tags ?? []),
            tasks: tasks,
            architecture: payload.architectures?.first,
            description: payload.cardData?["model_summary"]?.stringValue,
            source: .huggingFace,
            sourceURL: baseURL.appendingPathComponent(repositoryID),
            revision: payload.sha,
            license: ModelLicenseMetadata(
                identifier: payload.cardData?["license"]?.stringValue,
                url: payload.cardData?["license_link"]?.stringValue.flatMap(URL.init(string:))
            ),
            gated: payload.gated?.boolValue ?? false,
            supportedLanguages: payload.cardData?["language"]?.stringArrayValue ?? [],
            variants: variants
        )
    }

    private func makeVariants(from payload: HuggingFaceModelPayload) -> [ModelVariant] {
        guard let siblings = payload.siblings else { return [] }
        let revision = payload.sha ?? "main"
        let isKnownMLXRepository = payload.id.lowercased().hasPrefix("mlx-community/") ||
            (payload.tags ?? []).contains { $0.lowercased() == "mlx" }
        let isGated = payload.gated?.indicatesGated ?? false
        var variants: [ModelVariant] = []

        if isKnownMLXRepository {
            let mlxResources = siblings
                .filter { isMLXResource($0.rfilename) }
                .map { sibling in
                    ModelResource(
                        name: sibling.rfilename,
                        url: artifactURL(repositoryID: payload.id, revision: revision, filename: sibling.rfilename),
                        relativePath: sibling.rfilename,
                        sizeBytes: sibling.size ?? sibling.lfs?.size,
                        sha256: sibling.lfs?.sha256
                    )
                }
            let hasConfiguration = mlxResources.contains { $0.relativePath.lowercased().hasSuffix("config.json") }
            let hasTokenizer = mlxResources.contains { resource in
                let path = resource.relativePath.lowercased()
                return path.hasSuffix("tokenizer.json") ||
                    path.hasSuffix("tokenizer.model") ||
                    path.hasSuffix("vocab.json")
            }
            if hasConfiguration,
               hasTokenizer,
               let primary = mlxResources.first(where: { $0.relativePath.lowercased().hasSuffix(".safetensors") }) {
                let sizes = mlxResources.map(\.sizeBytes)
                let totalSize = sizes.allSatisfy { $0 != nil } ? sizes.compactMap { $0 }.reduce(0, +) : nil
                variants.append(ModelVariant(
                    id: "\(payload.id)#mlx",
                    name: "MLX package",
                    modelID: payload.id,
                    source: .huggingFace,
                    downloadURL: primary.url,
                    format: .mlx,
                    runtime: .mlx,
                    architecture: payload.architectures?.first,
                    supportedDeviceArchitectures: ["arm64"],
                    supportedPlatforms: Set(ArchonPlatform.allCases),
                    parameterCount: parameterCount(from: payload.tags ?? []),
                    contextLength: contextLength(from: payload.tags ?? []),
                    precision: quantization(from: primary.relativePath),
                    quantization: quantization(from: primary.relativePath),
                    sizeBytes: totalSize,
                    estimatedMemoryBytes: totalSize.map { Int64(Double($0) * 1.15) },
                    resources: mlxResources,
                    capabilities: ArchonModelCapabilities(tasks: [task(for: payload.pipelineTag)]),
                    requiresAuthentication: payload.private ?? false || isGated
                ))
            }
        }

        let mlxPaths = Set(variants.flatMap { $0.resources.map(\.relativePath) })
        variants.append(contentsOf: siblings.compactMap { sibling in
            let filename = sibling.rfilename
            let lowercased = filename.lowercased()
            guard !mlxPaths.contains(filename) else { return nil }
            let format: ArchonModelFormat
            let runtime: ArchonModelRuntime
            if lowercased.hasSuffix(".aimodel") {
                format = .aimodel
                runtime = .coreAI
            } else if lowercased.hasSuffix(".gguf") {
                format = .gguf
                runtime = .unknown
            } else if lowercased.hasSuffix(".safetensors") {
                format = .safetensors
                runtime = .unknown
            } else if [".bin", ".pt", ".pth", ".ckpt"].contains(where: { lowercased.hasSuffix($0) }) {
                format = .transformers
                runtime = .unknown
            } else {
                return nil
            }

            let size = sibling.size ?? sibling.lfs?.size
            return ModelVariant(
                id: "\(payload.id)#\(filename)",
                name: filename,
                modelID: payload.id,
                source: .huggingFace,
                downloadURL: artifactURL(repositoryID: payload.id, revision: revision, filename: filename),
                format: format,
                runtime: runtime,
                architecture: payload.architectures?.first,
                supportedDeviceArchitectures: ["arm64"],
                supportedPlatforms: Set(ArchonPlatform.allCases),
                parameterCount: parameterCount(from: payload.tags ?? []),
                contextLength: contextLength(from: payload.tags ?? []),
                precision: quantization(from: filename),
                quantization: quantization(from: filename),
                sizeBytes: size,
                estimatedMemoryBytes: size.map { Int64(Double($0) * 1.15) },
                capabilities: ArchonModelCapabilities(tasks: [task(for: payload.pipelineTag)]),
                requiresAuthentication: payload.private ?? false || isGated
            )
        })
        return variants
    }

    private func filtered(_ model: ModelDescriptor, for request: ModelSearchRequest) -> ModelDescriptor? {
        guard request.task == nil || model.tasks.contains(request.task!) else { return nil }
        let filteredVariants = model.variants.filter { variant in
            (request.runtime == nil || variant.runtime == request.runtime) &&
            (request.format == nil || variant.format == request.format) &&
            (!request.compatibleOnly || request.device.map { ModelCompatibilityAnalyzer.analyze(variant: variant, device: $0).canLoad } == true)
        }
        guard !request.compatibleOnly || !filteredVariants.isEmpty else { return nil }
        return ModelDescriptor(
            id: model.id,
            name: model.name,
            publisher: model.publisher,
            family: model.family,
            parameterCount: model.parameterCount,
            tasks: model.tasks,
            architecture: model.architecture,
            description: model.description,
            source: model.source,
            sourceURL: model.sourceURL,
            revision: model.revision,
            license: model.license,
            gated: model.gated,
            supportedLanguages: model.supportedLanguages,
            variants: request.includeVariants ? filteredVariants : []
        )
    }

    private func artifactURL(repositoryID: String, revision: String, filename: String) -> URL {
        baseURL
            .appendingPathComponent(repositoryID)
            .appendingPathComponent("resolve")
            .appendingPathComponent(revision)
            .appendingPathComponent(filename)
    }

    private func isMLXResource(_ filename: String) -> Bool {
        let lowercased = filename.lowercased()
        let excluded = ["readme", "license", ".gitattributes"]
        guard !excluded.contains(where: { lowercased.hasPrefix($0) }) else { return false }
        return [".safetensors", ".json", ".jinja", ".model", ".txt"].contains { lowercased.hasSuffix($0) }
    }

    private static func repositoryID(from query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed),
           let host = url.host?.lowercased(),
           host == "huggingface.co" || host == "www.huggingface.co" {
            let components = url.path.split(separator: "/").map(String.init)
            guard components.count >= 2 else { return nil }
            return components.prefix(2).joined(separator: "/")
        }
        let components = trimmed.split(separator: "/").map(String.init)
        guard components.count == 2, !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        return trimmed
    }

    private func task(for pipelineTag: String?) -> ArchonModelTask {
        switch pipelineTag?.lowercased() {
        case "text-generation", "text2text-generation": .textGeneration
        case "image-text-to-text", "image-to-text", "visual-question-answering": .vision
        case "automatic-speech-recognition", "audio-classification": .audio
        case "feature-extraction", "sentence-similarity": .embedding
        case "text-classification", "zero-shot-classification": .classification
        default: .unknown
        }
    }

    private func parameterCount(from tags: [String]) -> Int64? {
        guard let tag = tags.first(where: { $0.range(of: #"\d+(?:\.\d+)?[bmk]"#, options: .regularExpression) != nil }),
              let match = tag.range(of: #"\d+(?:\.\d+)?[bmk]"#, options: .regularExpression) else { return nil }
        let value = tag[match].lowercased()
        let multiplier: Double = value.hasSuffix("b") ? 1_000_000_000 : value.hasSuffix("m") ? 1_000_000 : 1_000
        return Int64((Double(value.dropLast()) ?? 0) * multiplier)
    }

    private func contextLength(from tags: [String]) -> Int? {
        guard let tag = tags.first(where: { $0.lowercased().contains("context") }) else { return nil }
        return Int(tag.filter(\.isNumber))
    }

    private func quantization(from filename: String) -> String? {
        let lowercased = filename.lowercased()
        for value in ["q2", "q3", "q4", "q5", "q6", "q8", "f16", "bf16", "fp16"] where lowercased.contains(value) {
            return value.uppercased()
        }
        return nil
    }
}

private struct HuggingFaceModelPayload: Decodable, Sendable {
    let id: String
    let author: String?
    let pipelineTag: String?
    let tags: [String]?
    let architectures: [String]?
    let gated: JSONValue?
    let `private`: Bool?
    let sha: String?
    let cardData: [String: JSONValue]?
    let siblings: [HuggingFaceSibling]?

    enum CodingKeys: String, CodingKey {
        case id, author, tags, architectures, gated, sha, siblings
        case pipelineTag = "pipeline_tag"
        case `private`
        case cardData = "cardData"
    }
}

private struct HuggingFaceSibling: Decodable, Sendable {
    let rfilename: String
    let size: Int64?
    let lfs: HuggingFaceLFS?
}

private struct HuggingFaceLFS: Decodable, Sendable {
    let size: Int64?
    let sha256: String?
}

private enum JSONValue: Decodable, Sendable {
    case string(String)
    case bool(Bool)
    case number(Double)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        if case .string(let value) = self { return value == "true" }
        return nil
    }

    var indicatesGated: Bool {
        if case .bool(let value) = self { return value }
        if case .string(let value) = self {
            return value == "true" || value == "auto"
        }
        return false
    }

    var stringArrayValue: [String]? {
        guard case .array(let values) = self else { return nil }
        return values.compactMap(\.stringValue)
    }
}
