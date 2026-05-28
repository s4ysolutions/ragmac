import Foundation

/// Produces fixed-dimensional vector embeddings for text.
public protocol Embedder: Sendable {
    var dimensions: Int { get }
    var identifier: String { get }
    var source: ModelSource { get }

    func embed(_ text: String) async throws -> [Float]
    func embedBatch(_ texts: [String]) async throws -> [[Float]]
}

public extension Embedder {
    /// Default serial implementation; override for batch-optimized models.
    func embedBatch(_ texts: [String]) async throws -> [[Float]] {
        var results: [[Float]] = []
        results.reserveCapacity(texts.count)
        for text in texts {
            results.append(try await embed(text))
        }
        return results
    }
}

/// Normalizes a vector to unit length for cosine similarity via L2 distance.
public func normalizeVector(_ v: [Float]) -> [Float] {
    let magnitude = sqrt(v.reduce(0) { $0 + $1 * $1 })
    guard magnitude > 0 else { return v }
    return v.map { $0 / magnitude }
}

/// Serializes a float array to a raw blob for sqlite-vec storage.
public func floatsToBlob(_ floats: [Float]) -> Data {
    floats.withUnsafeBufferPointer { Data(buffer: $0) }
}
