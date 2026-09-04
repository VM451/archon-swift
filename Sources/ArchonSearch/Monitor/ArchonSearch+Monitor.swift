import Foundation

extension ArchonSearch {
    
    /// Begin monitoring a query at the specified cadence, yielding new results through an async stream
    /// and optionally POSTing them to a user-supplied webhook URL.
    public func startMonitor(
        query: String,
        cadence: TimeInterval,
        source: DiscoverySource = .duckDuckGo,
        maxResults: Int = 10,
        livecrawl: LivecrawlPolicy = .fast,
        webhookURL: URL? = nil
    ) -> ArchonSearchMonitor {
        let configuration = ArchonSearchMonitor.Configuration(
            query: query,
            cadence: cadence,
            source: source,
            maxResults: maxResults,
            livecrawl: livecrawl,
            webhookURL: webhookURL
        )
        return ArchonSearchMonitor(searchEngine: self, configuration: configuration)
    }
}
