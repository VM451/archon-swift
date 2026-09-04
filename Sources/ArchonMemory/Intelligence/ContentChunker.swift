import Foundation

/// Fast on-device chunking and semantic tagging engine for document and web page ingestion (inspired by Supermemory).
public struct ContentChunker: Sendable {
    public let chunkSize: Int
    public let chunkOverlap: Int

    public init(chunkSize: Int = 500, chunkOverlap: Int = 100) {
        self.chunkSize = max(1, chunkSize)
        self.chunkOverlap = min(max(0, chunkOverlap), max(0, chunkSize - 1))
    }

    /// Split long document text into overlapping chunks for vector embedding and retrieval.
    public func chunk(text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > chunkSize else {
            return [trimmed]
        }

        var chunks: [String] = []
        let paragraphs = trimmed.components(separatedBy: "\n\n")
        var currentChunk = ""

        for para in paragraphs {
            if para.count > chunkSize && currentChunk.isEmpty {
                var start = para.startIndex
                while start < para.endIndex {
                    let end = para.index(start, offsetBy: chunkSize, limitedBy: para.endIndex) ?? para.endIndex
                    chunks.append(String(para[start..<end]))
                    if end == para.endIndex { break }
                    start = para.index(end, offsetBy: -min(chunkOverlap, para.distance(from: start, to: end)), limitedBy: para.endIndex) ?? end
                }
                continue
            }
            if (currentChunk.count + para.count) > chunkSize && !currentChunk.isEmpty {
                chunks.append(currentChunk.trimmingCharacters(in: .whitespacesAndNewlines))
                // Retain overlap tail
                let tail = String(currentChunk.suffix(chunkOverlap))
                currentChunk = tail + "\n\n" + para
            } else {
                if currentChunk.isEmpty {
                    currentChunk = para
                } else {
                    currentChunk += "\n\n" + para
                }
            }
        }

        if !currentChunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chunks.append(currentChunk.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return chunks
    }

    /// Extract automatic semantic tags and topics from content.
    public func extractTags(text: String) -> [String] {
        let words = text.lowercased().components(separatedBy: .alphanumerics.inverted).filter { $0.count >= 4 }
        let stopWords: Set<String> = ["this", "that", "with", "from", "have", "more", "will", "your", "they", "were", "been"]
        
        var frequencies: [String: Int] = [:]
        for w in words where !stopWords.contains(w) {
            frequencies[w, default: 0] += 1
        }

        let sorted = frequencies.sorted { $0.value > $1.value }
        return Array(sorted.prefix(5).map { $0.key })
    }
}
