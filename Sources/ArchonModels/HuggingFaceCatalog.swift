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

public struct HuggingFaceCatalog: PaginatedModelCatalogProvider, Sendable {
    public let id: String = "huggingface"
    public let baseURL: URL
    public let session: any ModelHTTPClient
    public let tokenStore: (any ModelTokenStore)?
    /// Optional first-party namespace used to narrow Hub searches before the
    /// response is downloaded. Repository inspection remains available for an
    /// explicit repository query and is still checked by the caller's policy.
    public let organization: String?

    public init(
        baseURL: URL = URL(string: "https://huggingface.co")!,
        session: (any ModelHTTPClient)? = nil,
        tokenStore: (any ModelTokenStore)? = KeychainModelTokenStore(),
        organization: String? = nil
    ) {
        self.baseURL = baseURL
        self.session = session ?? ModelDownloadURLPolicy.makeSession()
        self.tokenStore = tokenStore
        let normalizedOrganization = organization?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.organization = normalizedOrganization?.isEmpty == false ? normalizedOrganization : nil
    }

    /// Searches Hub metadata and repository inventories.
    ///
    /// An MLX runtime/format request is narrowed with the Hub's `mlx` tag so
    /// current runnable packages are not hidden behind the most-downloaded
    /// raw checkpoints. A broad search remains useful for conversion and
    /// inspection workflows, but raw formats are deliberately not runnable.
    public func search(_ request: ModelSearchRequest) async throws -> [ModelDescriptor] {
        try await searchPage(request).models
    }

    public func searchPage(_ request: ModelSearchRequest) async throws -> ModelCatalogPage {
        try ModelDownloadURLPolicy.validate(baseURL)
        if let repositoryID = Self.repositoryID(from: request.query) {
            guard request.offset == 0, request.continuationToken == nil else {
                return ModelCatalogPage(models: [], hasMore: false)
            }
            let model = try await inspect(repositoryID: repositoryID)
            guard let filteredModel = filtered(model, for: request) else {
                return ModelCatalogPage(models: [], hasMore: false)
            }
            return ModelCatalogPage(models: [filteredModel], hasMore: false)
        }
        let page = try await searchPayloads(for: request)

        var models: [ModelDescriptor] = []
        var seenRepositories = Set<String>()
        for payload in page.payloads where seenRepositories.insert(payload.id).inserted {
            let model = makeDescriptor(from: payload, includeVariants: true)
            guard let filteredModel = filtered(model, for: request) else { continue }
            models.append(filteredModel)
            // Filtering happens after the Hub response is decoded. Do not
            // stop at the first `request.limit` raw repositories because a
            // popular raw checkpoint can hide a later runnable package.
            if models.count == request.limit { break }
        }
        return ModelCatalogPage(
            models: models,
            hasMore: page.nextContinuationToken != nil,
            nextContinuationToken: page.nextContinuationToken
        )
    }

    /// Fetches a single repository's complete metadata and artifact inventory.
    public func inspect(repositoryID: String, revision: String? = nil) async throws -> ModelDescriptor {
        guard Self.isValidRepositoryID(repositoryID) else {
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

    private func response(for url: URL) async throws -> (Data, HTTPURLResponse) {
        try ModelDownloadURLPolicy.validate(url)
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = await tokenStore?.token(for: "huggingface.co") {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard data.count <= ModelDownloadURLPolicy.maximumResponseBytes else {
            throw ArchonModelsError.invalidResponse
        }
        guard let response = response as? HTTPURLResponse else { throw ArchonModelsError.invalidResponse }
        guard let finalURL = response.url,
              (try? ModelDownloadURLPolicy.validate(finalURL)) != nil,
              Self.isSameOrigin(finalURL, as: baseURL) else {
            throw ArchonModelsError.invalidResponse
        }
        guard (200...299).contains(response.statusCode) else {
            throw ArchonModelsError.httpFailure(statusCode: response.statusCode)
        }
        return (data, response)
    }

    private func data(for url: URL) async throws -> Data {
        let result = try await response(for: url)
        return result.0
    }

    private func searchPayloads(for request: ModelSearchRequest) async throws -> HuggingFaceSearchPage {
        let needsMLXFilter = request.runtime == .mlx || request.format == .mlx
        let needsCompatibilitySearch = request.compatibleOnly &&
            !needsMLXFilter &&
            request.runtime == nil &&
            request.format == nil
        let needsOverfetch = request.compatibleOnly ||
            (request.runtime != nil && !needsMLXFilter) ||
            (request.format != nil && !needsMLXFilter)
        let serverLimit = min(
            100,
            max(request.limit, request.limit * (needsOverfetch ? 3 : 1))
        )

        let urls: [URL]
        if let continuationToken = request.continuationToken {
            urls = try Self.urls(from: continuationToken, sameOriginAs: baseURL)
        } else {
            // The Hub's generic popularity list is dominated by raw
            // Transformers and SafeTensors repositories. A local-compatible
            // search must ask the Hub for its explicit `mlx` tag as well,
            // otherwise useful MLX packages may never reach this adapter's
            // local filtering stage.
            if needsMLXFilter {
                urls = [try makeSearchURL(for: request, limit: serverLimit, filter: "mlx")]
            } else {
                var initialURLs = [try makeSearchURL(for: request, limit: serverLimit, filter: nil)]
                if needsCompatibilitySearch {
                    initialURLs.insert(try makeSearchURL(for: request, limit: serverLimit, filter: "mlx"), at: 0)
                }
                urls = initialURLs
            }
        }

        var payloads: [HuggingFaceModelPayload] = []
        var nextURLs: [URL] = []
        for url in urls {
            let result = try await response(for: url)
            let data = result.0
            payloads.append(contentsOf: try JSONDecoder().decode([HuggingFaceModelPayload].self, from: data))
            if let nextURL = Self.nextPageURL(from: result.1, baseURL: baseURL),
               (try? ModelDownloadURLPolicy.validate(nextURL)) != nil,
               Self.isSameOrigin(nextURL, as: baseURL) {
                nextURLs.append(nextURL)
            }
        }
        return HuggingFaceSearchPage(
            payloads: payloads,
            nextContinuationToken: try Self.token(for: nextURLs)
        )
    }

    private func makeSearchURL(
        for request: ModelSearchRequest,
        limit: Int,
        filter: String?
    ) throws -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/models"), resolvingAgainstBaseURL: false)
        var queryItems = [
            URLQueryItem(name: "search", value: request.query),
            URLQueryItem(name: "limit", value: String(limit)),
            // Variant-level filters need the repository file inventory even
            // when the caller only wants compact result rows.
            URLQueryItem(
                name: "full",
                value: (request.includeVariants || request.compatibleOnly || request.runtime != nil || request.format != nil) ? "true" : "false"
            ),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1")
        ]
        if let organization {
            queryItems.append(URLQueryItem(name: "author", value: organization))
        }
        if let filter {
            queryItems.append(URLQueryItem(name: "filter", value: filter))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else { throw ArchonModelsError.invalidResponse }
        return url
    }

    private static func nextPageURL(from response: HTTPURLResponse, baseURL: URL) -> URL? {
        guard let linkHeader = response.value(forHTTPHeaderField: "Link") else { return nil }
        for link in linkHeader.split(separator: ",") {
            let value = String(link)
            guard let opening = value.firstIndex(of: "<"),
                  let closing = value.firstIndex(of: ">"),
                  opening < closing else { continue }
            let attributes = value[value.index(after: closing)...].lowercased()
            guard attributes.contains("rel=\"next\"") ||
                    attributes.contains("rel='next'") ||
                    attributes.contains("rel=next") else { continue }
            return URL(string: String(value[value.index(after: opening)..<closing]), relativeTo: baseURL)?.absoluteURL
        }
        return nil
    }

    private static func token(for urls: [URL]) throws -> String? {
        guard !urls.isEmpty else { return nil }
        let data = try JSONEncoder().encode(urls.map(\.absoluteString))
        return data.base64EncodedString()
    }

    private static func urls(from token: String, sameOriginAs baseURL: URL) throws -> [URL] {
        guard let data = Data(base64Encoded: token),
              let strings = try? JSONDecoder().decode([String].self, from: data),
              !strings.isEmpty else {
            throw ArchonModelsError.invalidResponse
        }
        let urls = strings.compactMap(URL.init(string:))
        guard urls.count == strings.count else { throw ArchonModelsError.invalidResponse }
        guard urls.allSatisfy({
            (try? ModelDownloadURLPolicy.validate($0)) != nil && isSameOrigin($0, as: baseURL)
        }) else {
            throw ArchonModelsError.invalidResponse
        }
        return urls
    }

    private static func isSameOrigin(_ lhs: URL, as rhs: URL) -> Bool {
        let left = URLComponents(url: lhs, resolvingAgainstBaseURL: false)
        let right = URLComponents(url: rhs, resolvingAgainstBaseURL: false)
        return left?.scheme?.lowercased() == right?.scheme?.lowercased()
            && left?.host?.lowercased() == right?.host?.lowercased()
            && left?.port == right?.port
    }

    private func makeDescriptor(from payload: HuggingFaceModelPayload, includeVariants: Bool) -> ModelDescriptor {
        let repositoryID = payload.id
        let publisher = payload.author ?? repositoryID.split(separator: "/").first.map(String.init) ?? "Unknown"
        let tags = payload.tags ?? []
        let tasks = tasks(for: payload.pipelineTag, tags: tags, repositoryID: repositoryID)
        let variants = includeVariants ? makeVariants(from: payload) : []
        return ModelDescriptor(
            id: repositoryID,
            name: repositoryID.split(separator: "/").last.map(String.init) ?? repositoryID,
            publisher: publisher,
            family: family(from: payload),
            parameterCount: parameterCount(from: tags, repositoryID: repositoryID),
            tasks: tasks,
            architecture: payload.architectures?.first,
            description: payload.cardData?["model_summary"]?.stringValue,
            logoURL: logoURL(for: payload, publisher: publisher),
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
        let tags = payload.tags ?? []
        let tasks = tasks(for: payload.pipelineTag, tags: tags, repositoryID: payload.id)
        let isKnownMLXRepository = payload.id.lowercased().hasPrefix("mlx-community/") ||
            payload.libraryName?.lowercased() == "mlx" ||
            tags.contains { $0.lowercased() == "mlx" }
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
                    parameterCount: parameterCount(from: tags, repositoryID: payload.id),
                    contextLength: contextLength(from: tags),
                    precision: quantization(from: primary.relativePath),
                    quantization: quantization(from: primary.relativePath),
                    sizeBytes: totalSize,
                    estimatedMemoryBytes: totalSize.map { Int64(Double($0) * 1.15) },
                    resources: mlxResources,
                    capabilities: capabilities(for: tasks, tags: tags),
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
                parameterCount: parameterCount(from: tags, repositoryID: payload.id),
                contextLength: contextLength(from: tags),
                precision: quantization(from: filename),
                quantization: quantization(from: filename),
                sizeBytes: size,
                estimatedMemoryBytes: size.map { Int64(Double($0) * 1.15) },
                capabilities: capabilities(for: tasks, tags: tags),
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
            logoURL: model.logoURL,
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

    /// Model cards commonly expose a `thumbnail` value, while older or
    /// provider-authored cards may use one of the other image keys. When no
    /// model-specific artwork is declared, use the Hub publisher avatar so
    /// every discovered model still has real artwork before the native
    /// fallback is needed.
    private func logoURL(for payload: HuggingFaceModelPayload, publisher: String) -> URL? {
        let imageKeys = ["logo", "logo_url", "thumbnail", "thumbnail_url", "image", "image_url"]
        for key in imageKeys {
            guard let value = payload.cardData?[key]?.stringValue,
                  let url = URL(string: value, relativeTo: baseURL)?.absoluteURL,
                  isAllowedLogoURL(url) else { continue }
            return url
        }

        let avatarPath = baseURL
            .appendingPathComponent("avatars")
            .appendingPathComponent(publisher)
        var components = URLComponents(url: avatarPath, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "s", value: "96")]
        guard let url = components?.url, isAllowedLogoURL(url) else { return nil }
        return url
    }

    private func isAllowedLogoURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https",
              let host = url.host, !host.isEmpty else { return false }
        return true
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

    private static func isValidRepositoryID(_ repositoryID: String) -> Bool {
        let components = repositoryID.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2 else { return false }
        let forbidden = CharacterSet.whitespacesAndNewlines
            .union(.controlCharacters)
            .union(CharacterSet(charactersIn: "?#\\"))
        return components.allSatisfy { component in
            !component.isEmpty &&
                component != "." &&
                component != ".." &&
                component.unicodeScalars.allSatisfy { !forbidden.contains($0) }
        }
    }

    private func tasks(
        for pipelineTag: String?,
        tags: [String],
        repositoryID: String
    ) -> Set<ArchonModelTask> {
        var result = Set<ArchonModelTask>()

        func insert(_ value: String?) {
            switch value?.lowercased() {
            case "text-generation", "text2text-generation", "text-to-text-generation":
                result.insert(.textGeneration)
            case "image-text-to-text", "image-to-text", "visual-question-answering", "any-to-any":
                // Multimodal checkpoints can still answer text-only prompts,
                // but vision requires a consuming-app model adapter.
                result.insert(.textGeneration)
                result.insert(.vision)
            case "automatic-speech-recognition", "audio-classification":
                result.insert(.audio)
            case "feature-extraction", "sentence-similarity", "text-embeddings":
                result.insert(.embedding)
            case "text-classification", "zero-shot-classification":
                result.insert(.classification)
            case "image-generation", "text-to-image":
                result.insert(.imageGeneration)
            default:
                break
            }
        }

        insert(pipelineTag)
        for tag in tags { insert(tag) }
        if result.isEmpty {
            let repositoryName = repositoryID.lowercased()
            if ["instruct", "chat", "causal", "language-model", "decoder", "llm"]
                .contains(where: { repositoryName.contains($0) }) {
                // This is task classification for discovery only. Runtime
                // compatibility still depends on the declared MLX artifact
                // and the consuming adapter.
                result.insert(.textGeneration)
            }
        }
        return result.isEmpty ? [.unknown] : result
    }

    private func parameterCount(from tags: [String], repositoryID: String) -> Int64? {
        let sources = (tags + [repositoryID]).map { $0.lowercased() }
        guard let tag = sources.first(where: { $0.range(of: #"\d+(?:\.\d+)?[bmk]"#, options: .regularExpression) != nil }),
              let match = tag.range(of: #"\d+(?:\.\d+)?[bmk]"#, options: .regularExpression) else { return nil }
        let value = tag[match]
        let multiplier: Double = value.hasSuffix("b") ? 1_000_000_000 : value.hasSuffix("m") ? 1_000_000 : 1_000
        return Int64((Double(value.dropLast()) ?? 0) * multiplier)
    }

    private func capabilities(for tasks: Set<ArchonModelTask>, tags: [String]) -> ArchonModelCapabilities {
        let normalizedTags = Set(tags.map { $0.lowercased() })
        return ArchonModelCapabilities(
            tasks: tasks,
            supportsStreaming: true,
            supportsToolCalling: normalizedTags.contains("tool-use") ||
                normalizedTags.contains("function-calling") ||
                normalizedTags.contains("tool-calling")
        )
    }

    private func family(from payload: HuggingFaceModelPayload) -> String? {
        let tags = payload.tags ?? []
        let baseModelTags = tags.filter {
            let normalized = $0.lowercased()
            return normalized.hasPrefix("base_model:") && !normalized.hasPrefix("base_model:quantized:")
        }
        let values = baseModelTags + tags + [payload.id] + (payload.architectures ?? [])
        let knownFamilies: [(String, String)] = [
            ("qwen", "Qwen"),
            ("mistral", "Mistral"),
            ("llama", "Llama"),
            ("gemma", "Gemma"),
            ("phi", "Phi"),
            ("deepseek", "DeepSeek"),
            ("granite", "Granite"),
            ("falcon", "Falcon"),
            ("whisper", "Whisper"),
            ("parakeet", "Parakeet"),
            ("bert", "BERT"),
            ("t5", "T5")
        ]
        for value in values {
            let normalized = value.lowercased()
            if let family = knownFamilies.first(where: { normalized.contains($0.0) })?.1 {
                return family
            }
        }
        return nil
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

private struct HuggingFaceSearchPage: Sendable {
    let payloads: [HuggingFaceModelPayload]
    let nextContinuationToken: String?
}

private struct HuggingFaceModelPayload: Decodable, Sendable {
    let id: String
    let author: String?
    let pipelineTag: String?
    let libraryName: String?
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
        case libraryName = "library_name"
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
