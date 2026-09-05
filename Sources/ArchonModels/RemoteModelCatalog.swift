import Foundation

/// HTTP-backed catalog for Apple-curated, Archon-hosted, or developer-hosted
/// registries. The endpoint returns either a JSON array of ModelDescriptor
/// values or an object containing `models`, optional `hasMore`, and optional
/// `nextContinuationToken` fields.
public struct RemoteModelCatalog: PaginatedModelCatalogProvider, Sendable {
    public let id: String
    public let endpoint: URL
    private let session: any ModelHTTPClient
    private let headers: [String: String]
    private let tokenStore: (any ModelTokenStore)?
    private let tokenService: String?

    public init(
        id: String,
        endpoint: URL,
        session: (any ModelHTTPClient)? = nil,
        headers: [String: String] = [:],
        tokenStore: (any ModelTokenStore)? = nil,
        tokenService: String? = nil
    ) {
        self.id = id
        self.endpoint = endpoint
        self.session = session ?? ModelDownloadURLPolicy.makeSession()
        self.headers = headers
        self.tokenStore = tokenStore
        self.tokenService = tokenService
    }

    public func search(_ request: ModelSearchRequest) async throws -> [ModelDescriptor] {
        try await searchPage(request).models
    }

    public func searchPage(_ request: ModelSearchRequest) async throws -> ModelCatalogPage {
        try ModelDownloadURLPolicy.validate(endpoint)
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        queryItems.append(contentsOf: [
            URLQueryItem(name: "query", value: request.query),
            URLQueryItem(name: "task", value: request.task?.rawValue),
            URLQueryItem(name: "runtime", value: request.runtime?.rawValue),
            URLQueryItem(name: "format", value: request.format?.rawValue),
            URLQueryItem(name: "compatibleOnly", value: request.compatibleOnly ? "true" : "false"),
            URLQueryItem(name: "offset", value: request.offset > 0 ? String(request.offset) : nil),
            URLQueryItem(name: "continuationToken", value: request.continuationToken),
            URLQueryItem(name: "limit", value: String(request.limit))
        ])
        components?.queryItems = queryItems.filter { $0.value != nil }
        guard let url = components?.url else { throw ArchonModelsError.invalidResponse }

        var httpRequest = URLRequest(url: url)
        httpRequest.timeoutInterval = 30
        httpRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        for (field, value) in headers {
            httpRequest.setValue(value, forHTTPHeaderField: field)
        }
        if let tokenService,
           let token = await tokenStore?.token(for: tokenService) {
            httpRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: httpRequest)
        guard data.count <= ModelDownloadURLPolicy.maximumResponseBytes else {
            throw ArchonModelsError.invalidResponse
        }
        guard let response = response as? HTTPURLResponse else { throw ArchonModelsError.invalidResponse }
        guard (200...299).contains(response.statusCode) else {
            throw ArchonModelsError.httpFailure(statusCode: response.statusCode)
        }
        return try decodePage(data, request: request)
    }

    private func decodePage(_ data: Data, request: ModelSearchRequest) throws -> ModelCatalogPage {
        let decoder = JSONDecoder()
        if let models = try? decoder.decode([ModelDescriptor].self, from: data) {
            return ModelCatalogPage(models: models, hasMore: models.count == request.limit)
        }
        if let response = try? decoder.decode(RemoteModelCatalogResponse.self, from: data) {
            return ModelCatalogPage(
                models: response.models,
                hasMore: response.hasMore ?? (response.models.count == request.limit),
                nextContinuationToken: response.nextContinuationToken
            )
        }
        throw ArchonModelsError.invalidResponse
    }
}

private struct RemoteModelCatalogResponse: Decodable {
    let models: [ModelDescriptor]
    let hasMore: Bool?
    let nextContinuationToken: String?

    enum CodingKeys: String, CodingKey {
        case models
        case hasMore = "hasMore"
        case nextContinuationToken = "nextContinuationToken"
    }
}
