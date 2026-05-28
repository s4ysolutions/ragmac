import Foundation

/// A text segment stored in the database after indexing.
public struct Chunk: Sendable, Codable {
    public let id: Int64
    public let fileId: Int64
    public let text: String
    public let position: Int
    public let startOffset: Int?
    public let endOffset: Int?

    public init(id: Int64, fileId: Int64, text: String, position: Int, startOffset: Int?, endOffset: Int?) {
        self.id = id
        self.fileId = fileId
        self.text = text
        self.position = position
        self.startOffset = startOffset
        self.endOffset = endOffset
    }
}

/// Raw chunk produced by Chunker before database insertion.
public struct ChunkContent: Sendable {
    public let text: String
    public let position: Int
    public let startOffset: Int
    public let endOffset: Int

    public init(text: String, position: Int, startOffset: Int, endOffset: Int) {
        self.text = text
        self.position = position
        self.startOffset = startOffset
        self.endOffset = endOffset
    }
}
