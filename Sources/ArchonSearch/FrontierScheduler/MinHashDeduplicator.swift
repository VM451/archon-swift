import Foundation

public struct MinHashDeduplicator: Sendable {
    private static let numHashes = 128
    // A prime number larger than the maximum possible hash value (we'll use a 64-bit prime)
    private static let prime: Int64 = 4294967291 // 2^32 - 5
    
    // Deterministic coefficients for the 128 hash functions: (a * x + b) % prime
    private static let coefficientsA: [Int64] = {
        var a = [Int64]()
        var seed: UInt64 = 123456789
        for _ in 0..<numHashes {
            seed = seed &* 2862933555777941757 &+ 3037000493
            let value = Int64(seed % UInt64(prime - 1)) + 1
            a.append(value)
        }
        return a
    }()
    
    private static let coefficientsB: [Int64] = {
        var b = [Int64]()
        var seed: UInt64 = 987654321
        for _ in 0..<numHashes {
            seed = seed &* 2862933555777941757 &+ 3037000493
            let value = Int64(seed % UInt64(prime))
            b.append(value)
        }
        return b
    }()
    
    /// Generates a MinHash signature for the given text using 3-word shingles.
    public static func generateSignature(from text: String) -> [Int64] {
        let shingles = getShingles(from: text)
        var signature = Array(repeating: Int64.max, count: numHashes)
        
        if shingles.isEmpty {
            return signature
        }
        
        for shingle in shingles {
            let shingleHash = Int64(truncatingIfNeeded: djb2Hash(shingle))
            for i in 0..<numHashes {
                // Compute (a * x + b) % prime
                // Use double width or overflow operators where needed, but we keep it safe
                let a = coefficientsA[i]
                let b = coefficientsB[i]
                let multiplied = shingleHash.multipliedReportingOverflow(by: a)
                let term = multiplied.overflow ? Double(shingleHash) * Double(a) : Double(multiplied.partialValue)
                let hashVal = Int64(abs(term + Double(b)).truncatingRemainder(dividingBy: Double(prime)))
                
                if hashVal < signature[i] {
                    signature[i] = hashVal
                }
            }
        }
        
        return signature
    }
    
    /// Computes the Jaccard similarity estimate between two MinHash signatures.
    public static func jaccardSimilarity(sig1: [Int64], sig2: [Int64]) -> Double {
        guard sig1.count == sig2.count, !sig1.isEmpty else { return 0.0 }
        
        var matches = 0
        for i in 0..<sig1.count {
            if sig1[i] == sig2[i] {
                matches += 1
            }
        }
        
        return Double(matches) / Double(sig1.count)
    }
    
    /// Tokenizes the text and generates 3-word shingles.
    private static func getShingles(from text: String) -> Set<String> {
        let words = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        
        var shingles = Set<String>()
        guard words.count >= 3 else {
            if !words.isEmpty {
                shingles.insert(words.joined(separator: " "))
            }
            return shingles
        }
        
        for i in 0..<(words.count - 2) {
            let shingle = words[i] + " " + words[i+1] + " " + words[i+2]
            shingles.insert(shingle)
        }
        
        return shingles
    }
    
    /// A simple string hash function (djb2) to map strings to hash integers.
    private static func djb2Hash(_ string: String) -> UInt32 {
        var hash: UInt32 = 5381
        for unicodeScalar in string.unicodeScalars {
            hash = ((hash << 5) &+ hash) &+ unicodeScalar.value
        }
        return hash
    }
}
