import Foundation

/// Tracks a source file that has been indexed into a corpus.
public struct IndexedFile: Sendable, Codable {
    public let id: Int64
    public let corpusId: Int64
    public let path: String
    public let description: String?
    public let mtime: Double
    public let size: Int64
    public let chunkCount: Int
    public let indexedAt: Date

    public init(id: Int64, corpusId: Int64, path: String, description: String? = nil, mtime: Double, size: Int64, chunkCount: Int, indexedAt: Date) {
        self.id = id
        self.corpusId = corpusId
        self.path = path
        self.description = description
        self.mtime = mtime
        self.size = size
        self.chunkCount = chunkCount
        self.indexedAt = indexedAt
    }
}
