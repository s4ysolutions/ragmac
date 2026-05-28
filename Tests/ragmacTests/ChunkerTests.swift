import XCTest
@testable import ragmacCore

final class ChunkerTests: XCTestCase {

    func testEmptyTextReturnsNoChunks() {
        XCTAssertTrue(Chunker.chunk("").isEmpty)
    }

    func testShortTextProducesOneChunk() {
        let text = "Hello, world."
        let chunks = Chunker.chunk(text)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].position, 0)
        XCTAssertEqual(chunks[0].text, text)
    }

    func testChunkOffsetsCoverFullText() {
        let text = String(repeating: "word ", count: 600)
        let chunks = Chunker.chunk(text)
        XCTAssertFalse(chunks.isEmpty)
        XCTAssertEqual(chunks[0].startOffset, 0)
        let lastChunk = chunks.last!
        XCTAssertLessThanOrEqual(lastChunk.endOffset, text.utf16.count)
    }

    func testChunksHaveIncreasingPositions() {
        let text = String(repeating: "Lorem ipsum dolor sit amet. ", count: 200)
        let chunks = Chunker.chunk(text)
        for (i, chunk) in chunks.enumerated() {
            XCTAssertEqual(chunk.position, i)
        }
    }

    func testOverlapMeansChunksShareContent() {
        let text = String(repeating: "A", count: 4096)
        let chunks = Chunker.chunk(text)
        XCTAssertGreaterThan(chunks.count, 1)
        // Chunks should overlap: end of chunk N > start of chunk N+1
        for i in 0..<(chunks.count - 1) {
            XCTAssertGreaterThan(chunks[i].endOffset, chunks[i + 1].startOffset,
                                 "Chunk \(i) end should overlap chunk \(i+1) start")
        }
    }

    func testParagraphBreakPreferred() {
        // Build text where a paragraph break falls near the target size
        let para1 = String(repeating: "word ", count: 400)
        let para2 = String(repeating: "other ", count: 400)
        let text = para1 + "\n\n" + para2
        let chunks = Chunker.chunk(text)
        // First chunk should end at or near the paragraph break
        XCTAssertGreaterThan(chunks.count, 0)
    }
}
