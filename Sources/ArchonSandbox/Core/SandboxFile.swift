import Foundation
import CryptoKit

/// Represents a virtual file residing within a `SandboxWorkspace`.
public struct SandboxFile: Identifiable, Sendable, Codable, Hashable, Equatable {
    public var id: String { path }
    
    /// Relative path inside the virtual sandbox (e.g., "index.html", "src/app.js", "assets/model.wasm").
    public let path: String
    
    /// Content stored as either UTF-8 text or raw binary data.
    public var content: FileContent
    
    /// The MIME type describing the file content (e.g. "text/html", "application/javascript", "application/wasm").
    public var mimeType: String
    
    /// SHA-256 cryptographic checksum of the file content for tamper-evidence and CRDT delta synchronization.
    public var checksum: String
    
    /// Size of the file in bytes.
    public var sizeInBytes: Int {
        content.byteLength
    }
    
    /// Last modification timestamp for this specific file.
    public var lastModified: Date
    
    public enum FileContent: Sendable, Codable, Hashable, Equatable {
        case text(String)
        case binary(Data)
        
        public var byteLength: Int {
            switch self {
            case .text(let string):
                return string.utf8.count
            case .binary(let data):
                return data.count
            }
        }
        
        public var rawData: Data {
            switch self {
            case .text(let string):
                return Data(string.utf8)
            case .binary(let data):
                return data
            }
        }
        
        public var utf8Text: String? {
            switch self {
            case .text(let string):
                return string
            case .binary(let data):
                return String(data: data, encoding: .utf8)
            }
        }
    }
    
    public init(
        path: String,
        content: FileContent,
        mimeType: String? = nil,
        lastModified: Date = Date()
    ) {
        // Normalize path (strip leading slashes)
        let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        self.path = normalizedPath
        self.content = content
        self.mimeType = mimeType ?? Self.inferMimeType(from: normalizedPath)
        self.lastModified = lastModified
        self.checksum = Self.computeChecksum(for: content.rawData)
    }
    
    /// Convenience initializer for text files.
    public init(path: String, text: String, mimeType: String? = nil, lastModified: Date = Date()) {
        self.init(path: path, content: .text(text), mimeType: mimeType, lastModified: lastModified)
    }
    
    /// Convenience initializer for binary files.
    public init(path: String, data: Data, mimeType: String? = nil, lastModified: Date = Date()) {
        self.init(path: path, content: .binary(data), mimeType: mimeType, lastModified: lastModified)
    }
    
    /// Computes SHA-256 hexadecimal hash string for data.
    public static func computeChecksum(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    /// Infers standard MIME types based on file path extension.
    public static func inferMimeType(from path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "html", "htm":
            return "text/html; charset=utf-8"
        case "css":
            return "text/css; charset=utf-8"
        case "js", "mjs":
            return "application/javascript; charset=utf-8"
        case "json":
            return "application/json; charset=utf-8"
        case "wasm":
            return "application/wasm"
        case "svg":
            return "image/svg+xml"
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "ico":
            return "image/x-icon"
        case "txt", "md":
            return "text/plain; charset=utf-8"
        case "pdf":
            return "application/pdf"
        case "mp3":
            return "audio/mpeg"
        case "mp4":
            return "video/mp4"
        case "woff2":
            return "font/woff2"
        case "woff":
            return "font/woff"
        case "ttf":
            return "font/ttf"
        default:
            return "application/octet-stream"
        }
    }
    
    /// Updates file content and automatically recalculates checksum and modification date.
    public mutating func updateContent(_ newContent: FileContent) {
        self.content = newContent
        self.lastModified = Date()
        self.checksum = Self.computeChecksum(for: newContent.rawData)
    }
}
