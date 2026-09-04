import Foundation
import CryptoKit

/// Handles chunking, checksumming, and file-coordination for large binary assets (e.g., WebAssembly .wasm binaries and static media) synced via CloudKit `CKAsset`.
public enum AssetChunkManager: Sendable {
    
    public static let defaultChunkSize = 750 * 1024 // 750 KB chunks
    
    public struct ChunkDescriptor: Sendable, Codable, Equatable {
        public let chunkIndex: Int
        public let totalChunks: Int
        public let checksum: String
        public let byteCount: Int
    }
    
    /// Splits a large data buffer into smaller chunks for incremental sync.
    public static func chunkData(_ data: Data, chunkSize: Int = defaultChunkSize) -> [(descriptor: ChunkDescriptor, chunkData: Data)] {
        guard !data.isEmpty else { return [] }
        
        var chunks: [(descriptor: ChunkDescriptor, chunkData: Data)] = []
        let totalChunks = Int(ceil(Double(data.count) / Double(chunkSize)))
        
        for index in 0..<totalChunks {
            let start = index * chunkSize
            let end = min(start + chunkSize, data.count)
            let subData = data.subdata(in: start..<end)
            
            let digest = SHA256.hash(data: subData)
            let checksum = digest.map { String(format: "%02x", $0) }.joined()
            
            let descriptor = ChunkDescriptor(
                chunkIndex: index,
                totalChunks: totalChunks,
                checksum: checksum,
                byteCount: subData.count
            )
            chunks.append((descriptor, subData))
        }
        
        return chunks
    }
    
    /// Reassembles ordered chunks into the original Data buffer while verifying checksums.
    public static func reassembleChunks(_ chunks: [(descriptor: ChunkDescriptor, chunkData: Data)]) throws -> Data {
        let sorted = chunks.sorted(by: { $0.descriptor.chunkIndex < $1.descriptor.chunkIndex })
        var assembled = Data()
        
        for (desc, chunkData) in sorted {
            let digest = SHA256.hash(data: chunkData)
            let actualChecksum = digest.map { String(format: "%02x", $0) }.joined()
            guard actualChecksum == desc.checksum else {
                throw SandboxError.serializationFailed("Chunk \(desc.chunkIndex) checksum mismatch: expected \(desc.checksum), got \(actualChecksum)")
            }
            assembled.append(chunkData)
        }
        
        return assembled
    }
}
