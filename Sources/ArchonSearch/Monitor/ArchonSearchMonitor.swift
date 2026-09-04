import Foundation

/// An on-device monitor that polls a query at a cadence and reports new results.
/// Supports an optional user-supplied webhook URL for local or remote callbacks.
public actor ArchonSearchMonitor {
    public struct Configuration: Sendable, Codable {
        public let query: String
        public let cadence: TimeInterval
        public let source: DiscoverySource
        public let maxResults: Int
        public let livecrawl: LivecrawlPolicy
        public let webhookURL: URL?
        
        public init(query: String, cadence: TimeInterval, source: DiscoverySource = .duckDuckGo, maxResults: Int = 10, livecrawl: LivecrawlPolicy = .fast, webhookURL: URL? = nil) {
            self.query = query
            self.cadence = cadence
            self.source = source
            self.maxResults = maxResults
            self.livecrawl = livecrawl
            self.webhookURL = webhookURL
        }
    }
    
    public struct Event: Sendable, Codable {
        public let timestamp: Date
        public let newResults: [SearchResult]
        
        public init(timestamp: Date = Date(), newResults: [SearchResult]) {
            self.timestamp = timestamp
            self.newResults = newResults
        }
    }
    
    public let configuration: Configuration
    public let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let searchEngine: ArchonSearch
    private var task: Task<Void, any Error>?
    
    public init(searchEngine: ArchonSearch, configuration: Configuration) {
        self.searchEngine = searchEngine
        let safeCadence = configuration.cadence.isFinite ? min(max(configuration.cadence, 0.1), 86_400) : 1
        self.configuration = Configuration(
            query: configuration.query,
            cadence: safeCadence,
            source: configuration.source,
            maxResults: min(max(configuration.maxResults, 0), 100),
            livecrawl: configuration.livecrawl,
            webhookURL: configuration.webhookURL.flatMap { SearchURLPolicy.validate($0) ? $0 : nil }
        )
        let (stream, cont) = AsyncStream.makeStream(of: Event.self)
        self.events = stream
        self.continuation = cont
    }
    
    deinit {
        task?.cancel()
    }
    
    public func start() {
        guard task == nil else { return }
        let config = self.configuration
        let engine = self.searchEngine
        let cont = self.continuation
        task = Task {
            var seen = Set<URL>()
            while !Task.isCancelled {
                do {
                    let results = try await engine.search(
                        query: config.query,
                        source: config.source,
                        maxResults: config.maxResults,
                        livecrawl: config.livecrawl
                    )
                    let newResults = results.filter { !seen.contains($0.url) }
                    if !newResults.isEmpty {
                        seen.formUnion(newResults.map(\.url))
                        let event = Event(timestamp: Date(), newResults: newResults)
                        cont.yield(event)
                        if let webhookURL = config.webhookURL {
                            try? await post(event, to: webhookURL)
                        }
                    }
                    try await Task.sleep(nanoseconds: UInt64(config.cadence * 1_000_000_000))
                } catch is CancellationError {
                    break
                } catch {
                    cont.yield(Event(timestamp: Date(), newResults: []))
                    do {
                        try await Task.sleep(nanoseconds: UInt64(config.cadence * 1_000_000_000))
                    } catch {
                        break
                    }
                }
            }
            cont.finish()
        }
    }
    
    public func stop() {
        task?.cancel()
        task = nil
        continuation.finish()
    }
    
    private nonisolated func post(_ event: Event, to url: URL) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let data = try JSONEncoder().encode(event)
        _ = try await URLSession.shared.upload(for: request, from: data)
    }
}
