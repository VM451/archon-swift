import Foundation

/// Manages citation indexing, context attribution formatting, and generated output verification.
public struct CitationGraph: Sendable {
    private var indexedSources: [Int: Source] = [:]
    private var passageMap: [String: (source: Source, passage: SourcePassage)] = [:]

    public init(sources: [Source] = []) {
        for (idx, source) in sources.enumerated() {
            register(source: source, index: idx + 1)
        }
    }

    /// Registers a source and its passages under a 1-based index.
    public mutating func register(source: Source, index: Int) {
        indexedSources[index] = source
        for (pIdx, passage) in source.passages.enumerated() {
            let key = "S\(index)/P\(pIdx + 1)"
            passageMap[key] = (source, passage)
        }
    }

    /// Formats a source and passage tag string, e.g. `[SOURCE:S1/P2]`.
    public static func tag(sourceIndex: Int, passageIndex: Int) -> String {
        "[SOURCE:S\(sourceIndex)/P\(passageIndex)]"
    }

    /// Parsed citation reference from model text.
    public struct CitationReference: Sendable, Equatable {
        public let rawToken: String
        public let sourceIndex: Int
        public let passageIndex: Int?

        public init(rawToken: String, sourceIndex: Int, passageIndex: Int? = nil) {
            self.rawToken = rawToken
            self.sourceIndex = sourceIndex
            self.passageIndex = passageIndex
        }
    }

    /// Parses citations from generated model text, matching `[S1]`, `[1]`, or `[S1/P2]`.
    public func parseCitations(from text: String) -> [CitationReference] {
        let pattern = #"(?:\[SOURCE:S?(\d+)(?:/P(\d+))?\]|\[S(\d+)(?:/P(\d+))?\]|\[(\d+)\])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        var results: [CitationReference] = []

        for match in matches {
            guard let rawRange = Range(match.range, in: text) else { continue }
            let rawToken = String(text[rawRange])

            var sIndex: Int?
            var pIndex: Int?

            if match.range(at: 1).location != NSNotFound, let r1 = Range(match.range(at: 1), in: text) {
                sIndex = Int(text[r1])
                if match.range(at: 2).location != NSNotFound, let r2 = Range(match.range(at: 2), in: text) {
                    pIndex = Int(text[r2])
                }
            } else if match.range(at: 3).location != NSNotFound, let r3 = Range(match.range(at: 3), in: text) {
                sIndex = Int(text[r3])
                if match.range(at: 4).location != NSNotFound, let r4 = Range(match.range(at: 4), in: text) {
                    pIndex = Int(text[r4])
                }
            } else if match.range(at: 5).location != NSNotFound, let r5 = Range(match.range(at: 5), in: text) {
                sIndex = Int(text[r5])
            }

            if let sIndex {
                results.append(CitationReference(rawToken: rawToken, sourceIndex: sIndex, passageIndex: pIndex))
            }
        }
        return results
    }

    /// Verifies that every parsed citation exists in the retrieved source set.
    public func verify(citations: [CitationReference]) -> (valid: [CitationReference], hallucinations: [CitationReference]) {
        var valid: [CitationReference] = []
        var hallucinations: [CitationReference] = []
        for citation in citations {
            if indexedSources[citation.sourceIndex] != nil {
                valid.append(citation)
            } else {
                hallucinations.append(citation)
            }
        }
        return (valid, hallucinations)
    }

    /// Resolves parsed citation references to verified `Citation` domain objects.
    public func resolve(citations: [CitationReference]) -> [Citation] {
        var resolved: [Citation] = []
        var seen = Set<String>()

        for ref in citations {
            guard let source = indexedSources[ref.sourceIndex] else { continue }
            let key = "\(ref.sourceIndex):\(ref.passageIndex ?? 0)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            var snippet: String? = nil
            var passageID: UUID? = nil
            if let pIdx = ref.passageIndex, let mapped = passageMap["S\(ref.sourceIndex)/P\(pIdx)"] {
                snippet = mapped.passage.text
                passageID = mapped.passage.id
            } else if let firstPassage = source.passages.first {
                snippet = firstPassage.text
                passageID = firstPassage.id
            }

            let label = ref.passageIndex.map { "[S\(ref.sourceIndex)/P\($0)]" } ?? "[S\(ref.sourceIndex)]"
            resolved.append(Citation(
                label: label,
                sourceID: source.id,
                passageID: passageID,
                url: source.url,
                title: source.title,
                snippet: snippet
            ))
        }
        return resolved
    }

    /// Resolves all citations found within generated text, returning unverified and verified citations.
    public func resolveCitations(in text: String) -> (unverified: [CitationReference], citations: [Citation]) {
        let parsed = parseCitations(from: text)
        let (valid, hallucinations) = verify(citations: parsed)
        let resolved = resolve(citations: valid)
        return (hallucinations, resolved)
    }
}
