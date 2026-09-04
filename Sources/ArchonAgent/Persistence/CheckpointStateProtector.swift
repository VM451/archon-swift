import Foundation
import CryptoKit

/// Encrypts checkpoint state before it is written to SQLite or SwiftData.
/// The key is generated once and retained in the Apple Keychain; checkpoint
/// databases therefore do not contain portable plaintext agent state.
enum CheckpointStateProtector {
    private static let lock = NSLock()
    private static let keyService = "com.archon.agent.checkpoints"
    private static let keyAccount = "state-encryption-key-v1"
    private static let envelopePrefix = Data("ACSP1".utf8)

    static func seal(_ plaintext: Data) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key())
        guard let combined = box.combined else {
            throw GraphError.stateDeserializationFailed("Checkpoint encryption did not produce a complete envelope.")
        }
        return envelopePrefix + combined
    }

    static func open(_ ciphertext: Data) throws -> Data {
        guard ciphertext.starts(with: envelopePrefix) else {
            throw GraphError.stateDeserializationFailed("Checkpoint state is not encrypted with the Archon checkpoint envelope.")
        }
        let box = try AES.GCM.SealedBox(combined: ciphertext.dropFirst(envelopePrefix.count))
        return try AES.GCM.open(box, using: key())
    }

    private static func key() throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }

        let storage = KeychainStorage(service: keyService)
        if let encoded = try storage.get(key: keyAccount),
           let material = Data(base64Encoded: encoded), material.count == 32 {
            return SymmetricKey(data: material)
        }

        let generated = SymmetricKey(size: .bits256)
        let material = generated.withUnsafeBytes { Data($0) }
        try storage.save(key: keyAccount, value: material.base64EncodedString())
        return generated
    }
}
