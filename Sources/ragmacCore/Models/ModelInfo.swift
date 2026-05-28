import Foundation

/// The source of an embedding model.
public enum ModelSource: String, Sendable, Codable {
    case native
    case hf
    case local
}

/// Metadata about a stored embedding model.
public struct ModelInfo: Sendable, Codable {
    public let id: Int64
    public let source: ModelSource
    public let identifier: String
    public let dimensions: Int

    public init(id: Int64, source: ModelSource, identifier: String, dimensions: Int) {
        self.id = id
        self.source = source
        self.identifier = identifier
        self.dimensions = dimensions
    }
}
