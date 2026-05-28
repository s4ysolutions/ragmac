import XCTest
@testable import ragmacCore

final class DatabaseTests: XCTestCase {

    var db: Database!
    var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        // Skip sqlite-vec for unit tests — we test schema and CRUD only
        let dbPath = tmpDir.appendingPathComponent("test.db").path
        // Open without vec extension for schema tests
        db = try Database(path: dbPath, vecDylibPath: "/nonexistent/vec0.dylib")
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testCreateAndListCorpus() throws {
        let model = try db.upsertModel(source: .native, identifier: "native", dimensions: 512)
        let corpus = try db.createCorpus(name: "test", description: "test corpus", modelId: model.id)
        XCTAssertEqual(corpus.name, "test")
        XCTAssertEqual(corpus.description, "test corpus")

        let list = try db.listCorpora()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].name, "test")
    }

    func testDuplicateCorpusThrows() throws {
        let model = try db.upsertModel(source: .native, identifier: "native", dimensions: 512)
        _ = try db.createCorpus(name: "dup", description: nil, modelId: model.id)
        do {
            _ = try db.createCorpus(name: "dup", description: nil, modelId: model.id)
            XCTFail("Expected corpusAlreadyExists error")
        } catch RagmacError.corpusAlreadyExists {
            // expected
        }
    }

    func testDeleteCorpus() throws {
        let model = try db.upsertModel(source: .native, identifier: "native", dimensions: 512)
        let corpus = try db.createCorpus(name: "delete-me", description: nil, modelId: model.id)
        try db.deleteCorpus(id: corpus.id)
        let list = try db.listCorpora()
        XCTAssertTrue(list.isEmpty)
    }

    func testUpsertModel() throws {
        let m1 = try db.upsertModel(source: .native, identifier: "native", dimensions: 512)
        let m2 = try db.upsertModel(source: .native, identifier: "native", dimensions: 512)
        XCTAssertEqual(m1.id, m2.id, "Same model should not be inserted twice")
    }

    func testUpsertAndListFiles() throws {
        let model = try db.upsertModel(source: .native, identifier: "native", dimensions: 512)
        let corpus = try db.createCorpus(name: "files-test", description: nil, modelId: model.id)
        let file = try db.upsertFile(corpusId: corpus.id, path: "/tmp/test.txt", mtime: 1234.0, size: 100)
        XCTAssertEqual(file.path, "/tmp/test.txt")

        let files = try db.listFiles(corpusId: corpus.id)
        XCTAssertEqual(files.count, 1)
    }

    func testInsertAndFetchChunks() throws {
        let model = try db.upsertModel(source: .native, identifier: "native", dimensions: 512)
        let corpus = try db.createCorpus(name: "chunk-test", description: nil, modelId: model.id)
        let file = try db.upsertFile(corpusId: corpus.id, path: "/tmp/doc.txt", mtime: 0, size: 0)

        let chunks = [
            ChunkContent(text: "first chunk", position: 0, startOffset: 0, endOffset: 11),
            ChunkContent(text: "second chunk", position: 1, startOffset: 6, endOffset: 18),
        ]
        let ids = try db.insertChunks(chunks, fileId: file.id)
        XCTAssertEqual(ids.count, 2)

        let fetched = try db.fetchChunk(id: ids[0])
        XCTAssertEqual(fetched?.text, "first chunk")
        XCTAssertEqual(fetched?.position, 0)
    }
}
