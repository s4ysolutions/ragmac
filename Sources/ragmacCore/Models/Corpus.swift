import Foundation

/// A named collection of indexed documents sharing an embedding model.
public struct Corpus: Sendable, Codable {
    public let id: Int64
    public let name: String
    public let description: String?
    public let modelId: Int64
    public let createdAt: Date

    public init(id: Int64, name: String, description: String?, modelId: Int64, createdAt: Date) {
        self.id = id
        self.name = name
        self.description = description
        self.modelId = modelId
        self.createdAt = createdAt
    }
}
