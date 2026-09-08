import Foundation

/// A comprehensive research report synthesized from multi-source search and analysis.
public struct ResearchReport: Sendable, Codable, Equatable {
    
    /// A structured section within the research report.
    public struct Section: Sendable, Codable, Identifiable, Equatable {
        public let id: UUID
        public let heading: String
        public let content: String
        public let citations: [Citation]
        
        public init(
            id: UUID = UUID(),
            heading: String,
            content: String,
            citations: [Citation] = []
        ) {
            self.id = id
            self.heading = heading
            self.content = content
            self.citations = citations
        }
    }
    
    public let query: String
    public let summary: String
    public let sections: [Section]
    public let sources: [Source]
    public let citations: [Citation]
    public let diagnostics: SearchDiagnostics
    
    public init(
        query: String,
        summary: String,
        sections: [Section] = [],
        sources: [Source] = [],
        citations: [Citation] = [],
        diagnostics: SearchDiagnostics = SearchDiagnostics()
    ) {
        self.query = query
        self.summary = summary
        self.sections = sections
        self.sources = sources
        self.citations = citations
        self.diagnostics = diagnostics
    }
}
