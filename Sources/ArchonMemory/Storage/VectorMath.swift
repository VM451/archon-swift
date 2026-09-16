import Foundation
import Accelerate

/// SIMD Vector math operations powered by Apple's Accelerate vDSP framework.
public enum VectorMath: Sendable {
    /// Computes cosine similarity between two equal-length float vectors using Accelerate vDSP.
    /// Range: [-1.0, 1.0] (for normalized unit vectors: [0.0, 1.0])
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty,
              a.allSatisfy(\.isFinite), b.allSatisfy(\.isFinite) else { return 0.0 }
        
        var dotProduct: Float = 0.0
        var normA: Float = 0.0
        var normB: Float = 0.0
        
        vDSP_dotpr(a, 1, b, 1, &dotProduct, vDSP_Length(a.count))
        vDSP_dotpr(a, 1, a, 1, &normA, vDSP_Length(a.count))
        vDSP_dotpr(b, 1, b, 1, &normB, vDSP_Length(a.count))
        
        let denominator = sqrt(normA) * sqrt(normB)
        guard denominator.isFinite, denominator > 0 else { return 0 }
        let similarity = dotProduct / denominator
        return similarity.isFinite ? min(max(similarity, -1), 1) : 0
    }

    /// Computes cosine similarities between one query and many rows with two
    /// matrix multiplies instead of one vDSP triple per row. Rows whose
    /// length differs from the query score exactly 0.0, matching the scalar
    /// guard; scores may differ from `cosineSimilarity` by rounding only.
    public static func batchCosineSimilarities(query: [Float], rows: [[Float]]) -> [Float] {
        var result = [Float](repeating: 0, count: rows.count)
        let dimensions = query.count
        guard dimensions > 0, !rows.isEmpty else { return result }

        var flat: [Float] = []
        flat.reserveCapacity(rows.count * dimensions)
        var positions: [Int] = []
        for (index, row) in rows.enumerated() where row.count == dimensions {
            flat.append(contentsOf: row)
            positions.append(index)
        }
        guard !positions.isEmpty else { return result }

        let count = positions.count
        var dots = [Float](repeating: 0, count: count)
        guard flat.withUnsafeBufferPointer({ flatPointer in
            query.withUnsafeBufferPointer { queryPointer in
                dots.withUnsafeMutableBufferPointer { dotPointer in
                    guard let a = flatPointer.baseAddress,
                          let b = queryPointer.baseAddress,
                          let c = dotPointer.baseAddress else { return false }
                    vDSP_mmul(a, 1, b, 1, c, 1, vDSP_Length(count), 1, vDSP_Length(dimensions))
                    return true
                }
            }
        }) else { return result }

        var squares = [Float](repeating: 0, count: flat.count)
        vDSP_vsq(flat, 1, &squares, 1, vDSP_Length(flat.count))
        let ones = [Float](repeating: 1, count: dimensions)
        var rowNormsSquared = [Float](repeating: 0, count: count)
        squares.withUnsafeBufferPointer { squarePointer in
            ones.withUnsafeBufferPointer { onePointer in
                rowNormsSquared.withUnsafeMutableBufferPointer { normPointer in
                    guard let a = squarePointer.baseAddress,
                          let b = onePointer.baseAddress,
                          let c = normPointer.baseAddress else { return }
                    vDSP_mmul(a, 1, b, 1, c, 1, vDSP_Length(count), 1, vDSP_Length(dimensions))
                }
            }
        }

        var queryNormSquared: Float = 0
        vDSP_svesq(query, 1, &queryNormSquared, vDSP_Length(dimensions))
        let queryNorm = sqrt(queryNormSquared)
        for (position, index) in positions.enumerated() {
            let denominator = queryNorm * sqrt(rowNormsSquared[position])
            guard denominator.isFinite, denominator > 0 else { continue }
            let similarity = dots[position] / denominator
            result[index] = similarity.isFinite ? min(max(similarity, -1), 1) : 0
        }
        return result
    }

    /// Computes Euclidean distance between two float vectors using Accelerate vDSP.
    public static func euclideanDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return Float.greatestFiniteMagnitude }
        
        var difference = [Float](repeating: 0.0, count: a.count)
        vDSP_vsub(b, 1, a, 1, &difference, 1, vDSP_Length(a.count))
        
        var distanceSquared: Float = 0.0
        vDSP_svesq(difference, 1, &distanceSquared, vDSP_Length(a.count))
        return sqrt(distanceSquared)
    }

    /// Normalizes a float vector in-place or returns a normalized copy.
    public static func normalize(_ a: [Float]) -> [Float] {
        guard !a.isEmpty else { return [] }
        var normSq: Float = 0.0
        vDSP_svesq(a, 1, &normSq, vDSP_Length(a.count))
        let norm = sqrt(normSq)
        guard norm > 0 else { return a }
        
        var result = [Float](repeating: 0.0, count: a.count)
        var divisor = norm
        vDSP_vsdiv(a, 1, &divisor, &result, 1, vDSP_Length(a.count))
        return result
    }
}
