import Foundation

/// HTTP-backed catalog for Apple-curated, Archon-hosted, or developer-hosted
/// registries. The endpoint returns either a JSON array of ModelDescriptor
/// values or an object containing a models array.
public struct RemoteModelCatalog: ModelCatalogProvider, Sendable {
    public let id: String
    public let endpoint: URL
    private let session: any ModelHTTPClient
    private let headers: [String: String]
    private let tokenStore: (any ModelTokenStore)?
    private let tokenService: String?

    public init(
        id: String,
        endpoint: URL,
        session: any ModelHTTPClient = URLSession.shared,
        headers: [String: String] = [:],
        tokenStore: (any ModelTokenStore)? = nil,
        tokenService: String? = nil
    ) {
        self.id = id
        self.endpoint = endpoint
        self.session = session
        self.headers = headers
        self.tokenStore = tokenStore
        self.tokenService = tokenService
    }

    public func search(_ request: ModelSearchRequest) async throws -> [ModelDescriptor] {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        queryItems.append(contentsOf: [
            URLQueryItem(name: "query", value: request.query),
            URLQueryItem(name: "task", value: request.task?.rawValue),
            URLQueryItem(name: "runtime", value: request.runtime?.rawValue),
            URLQueryItem(name: "format", value: request.format?.rawValue),
            URLQueryItem(name: "compatibleOnly", value: request.compatibleOnly ? "true" : "false"),
            URLQueryItem(name: "limit", value: String(request.limit))
        ])
        components?.queryItems = queryItems.filter { $0.value != nil }
        guard let url = components?.url else { throw ArchonModelsError.invalidResponse }

        var httpRequest = URLRequest(url: url)
        httpRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        for (field, value) in headers {
            httpRequest.setValue(value, forHTTPHeaderField: field)
        }
        if let tokenService,
           let token = await tokenStore?.token(for: tokenService) {
            httpRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: httpRequest)
        guard let response = response as? HTTPURLResponse else { throw ArchonModelsError.invalidResponse }
        guard (200...299).contains(response.statusCode) else {
            throw ArchonModelsError.httpFailure(statusCode: response.statusCode)
        }
        return try decodeModels(data)
    }

    private func decodeModels(_ data: Data) throws -> [ModelDescriptor] {
        let decoder = JSONDecoder()
        if let models = try? decoder.decode([ModelDescriptor].self, from: data) {
            return models
        }
        if let response = try? decoder.decode(RemoteModelCatalogResponse.self, from: data) {
            return response.models
        }
        throw ArchonModelsError.invalidResponse
    }
}

private struct RemoteModelCatalogResponse: Decodable {
    let models: [ModelDescriptor]
}
