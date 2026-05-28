import Foundation
import NaturalLanguage

/// Uses macOS NLEmbedding for English sentence embeddings (no download required).
public final class NativeEmbedder: Embedder, @unchecked Sendable {
    public let dimensions: Int
    public let identifier: String = "native"
    public let source: ModelSource = .native

    private let embedding: NLEmbedding

    public init() throws {
        guard let emb = NLEmbedding.sentenceEmbedding(for: .english) else {
            throw RagmacError.modelLoadFailed(
                reason: "NLEmbedding.sentenceEmbedding(for: .english) is unavailable on this system"
            )
        }
        self.embedding = emb
        self.dimensions = emb.dimension
    }

    public func embed(_ text: String) async throws -> [Float] {
        guard let vector = embedding.vector(for: text) else {
            // NLEmbedding returns nil for empty strings; return zero vector
            return [Float](repeating: 0, count: dimensions)
        }
        return vector.map { Float($0) }
    }
}
