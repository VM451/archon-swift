import Foundation

/// An attribution citation mapping claims back to a specific source and passage.
public struct Citation: Sendable, Codable, Identifiable, Hashable {
    public let id: UUID
    public let label: String
    public let sourceID: UUID
    public let passageID: UUID?
    public let url: URL
    public let title: String?
    public let snippet: String?
    
    public init(
        id: UUID = UUID(),
        label: String,
        sourceID: UUID = UUID(),
        passageID: UUID? = nil,
        url: URL,
        title: String? = nil,
        snippet: String? = nil
    ) {
        self.id = id
        self.label = label
        self.sourceID = sourceID
        self.passageID = passageID
        self.url = url
        self.title = title
        self.snippet = snippet
    }

    /// Convenience initializer maintaining backwards compatibility with earlier API.
    public init(index: Int, sourceURLString: String, snippet: String? = nil) {
        self.id = UUID()
        self.label = "[\(index)]"
        self.sourceID = UUID()
        self.passageID = nil
        self.url = URL(string: sourceURLString) ?? URL(fileURLWithPath: "/")
        self.title = nil
        self.snippet = snippet
    }
    
    /// Numeric index derived from citation label if formatted as [1], [2], etc.
    public var index: Int {
        let trimmed = label.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return Int(trimmed) ?? 0
    }
    
    /// String representation of the source URL.
    public var sourceURLString: String {
        url.absoluteString
    }
}
