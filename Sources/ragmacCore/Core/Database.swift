import Foundation
import SQLite

/// Central database layer: schema, per-corpus vector tables, and all CRUD operations.
public final class Database: @unchecked Sendable {
    public let connection: Connection
    private let vecDylibPath: String

    // MARK: - Init

    public init(path: String, vecDylibPath: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        self.connection = try Connection(path)
        self.vecDylibPath = vecDylibPath
        try setup()
    }

    private func setup() throws {
        // Load sqlite-vec only if the dylib exists (skipped in unit tests)
        if FileManager.default.fileExists(atPath: vecDylibPath) {
            let handle = connection.handle
            try VecExtension.load(on: handle, dylibPath: vecDylibPath)
        }
        try connection.execute("PRAGMA foreign_keys = ON")
        try connection.execute("PRAGMA journal_mode = WAL")
        try createSchema()
    }

    private func createSchema() throws {
        try connection.execute("""
            CREATE TABLE IF NOT EXISTS models (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                source TEXT NOT NULL,
                identifier TEXT NOT NULL,
                dimensions INTEGER NOT NULL,
                UNIQUE(source, identifier)
            )
            """)
        try connection.execute("""
            CREATE TABLE IF NOT EXISTS corpora (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT UNIQUE NOT NULL,
                description TEXT,
                model_id INTEGER NOT NULL REFERENCES models(id),
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
            """)
        try connection.execute("""
            CREATE TABLE IF NOT EXISTS files (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                corpus_id INTEGER NOT NULL REFERENCES corpora(id) ON DELETE CASCADE,
                path TEXT NOT NULL,
                description TEXT,
                mtime REAL NOT NULL,
                size INTEGER NOT NULL,
                chunk_count INTEGER DEFAULT 0,
                indexed_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                UNIQUE(corpus_id, path)
            )
            """)
        // Migrate: add description column if it doesn't exist
        let hasDescription = (try? connection.prepare("PRAGMA table_info(files)")
            .compactMap { row in row[1] as? String }
            .contains("description")) ?? false
        if !hasDescription {
            try connection.execute("ALTER TABLE files ADD COLUMN description TEXT")
        }
        try connection.execute("""
            CREATE TABLE IF NOT EXISTS chunks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
                text TEXT NOT NULL,
                position INTEGER NOT NULL,
                start_offset INTEGER,
                end_offset INTEGER
            )
            """)
        try createFTSIndex()
    }

    /// Creates the BM25 full-text index over chunk text for hybrid (lexical + vector) search.
    /// This is an external-content FTS5 table mirroring `chunks`, kept in sync by triggers.
    /// `unicode61` with diacritic folding handles Serbian Latin/Cyrillic and other scripts.
    private func createFTSIndex() throws {
        let ftsExisted = ((try? connection.scalar(
            "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='chunks_fts'"
        )) as? Int64 ?? 0) > 0

        try connection.execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
                text,
                content='chunks',
                content_rowid='id',
                tokenize='unicode61 remove_diacritics 2'
            )
            """)
        // Keep the FTS index in sync with the chunks table.
        try connection.execute("""
            CREATE TRIGGER IF NOT EXISTS chunks_fts_ai AFTER INSERT ON chunks BEGIN
                INSERT INTO chunks_fts(rowid, text) VALUES (new.id, new.text);
            END
            """)
        try connection.execute("""
            CREATE TRIGGER IF NOT EXISTS chunks_fts_ad AFTER DELETE ON chunks BEGIN
                INSERT INTO chunks_fts(chunks_fts, rowid, text) VALUES ('delete', old.id, old.text);
            END
            """)
        try connection.execute("""
            CREATE TRIGGER IF NOT EXISTS chunks_fts_au AFTER UPDATE ON chunks BEGIN
                INSERT INTO chunks_fts(chunks_fts, rowid, text) VALUES ('delete', old.id, old.text);
                INSERT INTO chunks_fts(rowid, text) VALUES (new.id, new.text);
            END
            """)
        // Backfill rows that existed before the FTS index was added (one-time migration).
        if !ftsExisted {
            try connection.execute("INSERT INTO chunks_fts(chunks_fts) VALUES ('rebuild')")
        }
    }

    // MARK: - Models

    /// Inserts model if not present, returns stored ModelInfo.
    public func upsertModel(source: ModelSource, identifier: String, dimensions: Int) throws -> ModelInfo {
        try connection.run(
            "INSERT OR IGNORE INTO models (source, identifier, dimensions) VALUES (?, ?, ?)",
            source.rawValue, identifier, Int64(dimensions)
        )
        guard let row = try connection.prepare(
            "SELECT id, source, identifier, dimensions FROM models WHERE source = ? AND identifier = ?",
            source.rawValue, identifier
        ).makeIterator().next() else {
            throw RagmacError.databaseError(underlying: NSError(domain: "ragmac", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Model row not found after upsert"]))
        }
        return ModelInfo(
            id: row[0] as! Int64,
            source: ModelSource(rawValue: row[1] as! String) ?? .native,
            identifier: row[2] as! String,
            dimensions: Int(row[3] as! Int64)
        )
    }

    public func fetchModel(id: Int64) throws -> ModelInfo? {
        guard let row = try connection.prepare(
            "SELECT id, source, identifier, dimensions FROM models WHERE id = ?", id
        ).makeIterator().next() else { return nil }
        return ModelInfo(
            id: row[0] as! Int64,
            source: ModelSource(rawValue: row[1] as! String) ?? .native,
            identifier: row[2] as! String,
            dimensions: Int(row[3] as! Int64)
        )
    }

    // MARK: - Corpora

    public func createCorpus(name: String, description: String?, modelId: Int64) throws -> Corpus {
        do {
            try connection.run(
                "INSERT INTO corpora (name, description, model_id) VALUES (?, ?, ?)",
                name, description, modelId
            )
        } catch {
            let desc = "\(error)"
            if desc.contains("UNIQUE") || error.localizedDescription.contains("UNIQUE") {
                throw RagmacError.corpusAlreadyExists(name)
            }
            throw RagmacError.databaseError(underlying: error)
        }
        let id = connection.lastInsertRowid
        return try fetchCorpus(id: id)!
    }

    public func fetchCorpus(id: Int64) throws -> Corpus? {
        guard let row = try connection.prepare(
            "SELECT id, name, description, model_id, created_at FROM corpora WHERE id = ?", id
        ).makeIterator().next() else { return nil }
        return rowToCorpus(row)
    }

    public func fetchCorpus(name: String) throws -> Corpus? {
        guard let row = try connection.prepare(
            "SELECT id, name, description, model_id, created_at FROM corpora WHERE name = ?", name
        ).makeIterator().next() else { return nil }
        return rowToCorpus(row)
    }

    public func listCorpora() throws -> [Corpus] {
        try connection.prepare(
            "SELECT id, name, description, model_id, created_at FROM corpora ORDER BY name"
        ).compactMap { rowToCorpus($0) }
    }

    public func deleteCorpus(id: Int64) throws {
        try dropVectorTable(corpusId: id)
        try connection.run("DELETE FROM corpora WHERE id = ?", id)
    }

    public func corpusStats(id: Int64) throws -> (fileCount: Int, chunkCount: Int) {
        let fileCount = (try connection.prepare(
            "SELECT COUNT(*) FROM files WHERE corpus_id = ?", id
        ).makeIterator().next()?[0] as? Int64).map { Int($0) } ?? 0

        let chunkCount = (try connection.prepare(
            "SELECT COALESCE(SUM(chunk_count), 0) FROM files WHERE corpus_id = ?", id
        ).makeIterator().next()?[0] as? Int64).map { Int($0) } ?? 0

        return (fileCount, chunkCount)
    }

    private func rowToCorpus(_ row: Statement.Element) -> Corpus? {
        guard let id = row[0] as? Int64,
              let name = row[1] as? String,
              let modelId = row[3] as? Int64,
              let createdStr = row[4] as? String else { return nil }
        let date = sqliteDate(from: createdStr)
        return Corpus(id: id, name: name, description: row[2] as? String, modelId: modelId, createdAt: date)
    }

    // MARK: - Vector Tables

    public func createVectorTable(corpusId: Int64, dimensions: Int) throws {
        try connection.execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS chunk_embeddings_\(corpusId)
            USING vec0(
                chunk_id INTEGER PRIMARY KEY,
                embedding float[\(dimensions)]
            )
            """)
    }

    public func dropVectorTable(corpusId: Int64) throws {
        try connection.execute("DROP TABLE IF EXISTS chunk_embeddings_\(corpusId)")
    }

    // MARK: - Files

    public func upsertFile(corpusId: Int64, path: String, description: String? = nil, mtime: Double, size: Int64) throws -> IndexedFile {
        try connection.run(
            "INSERT OR REPLACE INTO files (corpus_id, path, description, mtime, size) VALUES (?, ?, ?, ?, ?)",
            corpusId, path, description, mtime, size
        )
        let id = connection.lastInsertRowid
        return try fetchFile(id: id)!
    }

    public func fetchFile(id: Int64) throws -> IndexedFile? {
        guard let row = try connection.prepare(
            "SELECT id, corpus_id, path, description, mtime, size, chunk_count, indexed_at FROM files WHERE id = ?", id
        ).makeIterator().next() else { return nil }
        return rowToFile(row)
    }

    public func fetchFile(corpusId: Int64, path: String) throws -> IndexedFile? {
        guard let row = try connection.prepare(
            "SELECT id, corpus_id, path, description, mtime, size, chunk_count, indexed_at FROM files WHERE corpus_id = ? AND path = ?",
            corpusId, path
        ).makeIterator().next() else { return nil }
        return rowToFile(row)
    }

    public func listFiles(corpusId: Int64) throws -> [IndexedFile] {
        try connection.prepare(
            "SELECT id, corpus_id, path, description, mtime, size, chunk_count, indexed_at FROM files WHERE corpus_id = ? ORDER BY path",
            corpusId
        ).compactMap { rowToFile($0) }
    }

    public func deleteFile(id: Int64, corpusId: Int64) throws {
        let chunkIds = try connection.prepare(
            "SELECT id FROM chunks WHERE file_id = ?", id
        ).compactMap { $0[0] as? Int64 }

        for chunkId in chunkIds {
            try connection.run("DELETE FROM chunk_embeddings_\(corpusId) WHERE chunk_id = ?", chunkId)
        }
        try connection.run("DELETE FROM files WHERE id = ?", id)
    }

    public func updateFileChunkCount(fileId: Int64, count: Int) throws {
        try connection.run("UPDATE files SET chunk_count = ? WHERE id = ?", Int64(count), fileId)
    }

    private func rowToFile(_ row: Statement.Element) -> IndexedFile? {
        guard let id = row[0] as? Int64,
              let corpusId = row[1] as? Int64,
              let path = row[2] as? String,
              let mtime = row[4] as? Double,
              let size = row[5] as? Int64,
              let chunkCount = row[6] as? Int64 else { return nil }
        let description = row[3] as? String
        let dateStr = row[7] as? String ?? ""
        return IndexedFile(id: id, corpusId: corpusId, path: path, description: description, mtime: mtime, size: size,
                           chunkCount: Int(chunkCount), indexedAt: sqliteDate(from: dateStr))
    }

    // MARK: - Chunks

    /// Inserts chunks and returns their assigned IDs.
    public func insertChunks(_ chunks: [ChunkContent], fileId: Int64) throws -> [Int64] {
        var ids: [Int64] = []
        for chunk in chunks {
            try connection.run(
                "INSERT INTO chunks (file_id, text, position, start_offset, end_offset) VALUES (?, ?, ?, ?, ?)",
                fileId, chunk.text, Int64(chunk.position), Int64(chunk.startOffset), Int64(chunk.endOffset)
            )
            ids.append(connection.lastInsertRowid)
        }
        return ids
    }

    public func fetchChunk(id: Int64) throws -> Chunk? {
        guard let row = try connection.prepare(
            "SELECT id, file_id, text, position, start_offset, end_offset FROM chunks WHERE id = ?", id
        ).makeIterator().next() else { return nil }
        return rowToChunk(row)
    }

    private func rowToChunk(_ row: Statement.Element) -> Chunk? {
        guard let id = row[0] as? Int64,
              let fileId = row[1] as? Int64,
              let text = row[2] as? String,
              let position = row[3] as? Int64 else { return nil }
        return Chunk(id: id, fileId: fileId, text: text, position: Int(position),
                     startOffset: (row[4] as? Int64).map { Int($0) },
                     endOffset: (row[5] as? Int64).map { Int($0) })
    }

    // MARK: - Embeddings

    public func insertEmbeddings(corpusId: Int64, chunkIds: [Int64], embeddings: [[Float]]) throws {
        for (chunkId, embedding) in zip(chunkIds, embeddings) {
            let normalized = normalizeVector(embedding)
            let blob = Blob(bytes: Array(floatsToBlob(normalized)))
            try connection.run(
                "INSERT OR REPLACE INTO chunk_embeddings_\(corpusId)(chunk_id, embedding) VALUES (?, ?)",
                chunkId, blob
            )
        }
    }

    // MARK: - Search

    public struct SearchResult: Sendable {
        public let chunkId: Int64
        public let text: String
        public let filePath: String
        public let corpusName: String
        public let position: Int
        public let score: Float
    }

    /// KNN search within a single corpus. Returns top-k results by cosine similarity.
    public func search(corpusId: Int64, corpusName: String, queryEmbedding: [Float], topK: Int) throws -> [SearchResult] {
        let normalized = normalizeVector(queryEmbedding)
        let blob = Blob(bytes: Array(floatsToBlob(normalized)))

        // sqlite-vec requires the LIMIT/k constraint on the vec0 table itself,
        // not on an outer JOIN. Use a subquery so the planner sees LIMIT on vec0.
        let sql = """
            SELECT e.chunk_id, e.distance, c.text, c.position, f.path
            FROM (
                SELECT chunk_id, distance
                FROM chunk_embeddings_\(corpusId)
                WHERE embedding MATCH ?
                ORDER BY distance
                LIMIT \(topK)
            ) e
            JOIN chunks c ON c.id = e.chunk_id
            JOIN files f ON f.id = c.file_id
            ORDER BY e.distance
            """

        return try connection.prepare(sql, blob).compactMap { row -> SearchResult? in
            guard let chunkId = row[0] as? Int64,
                  let distance = row[1] as? Double,
                  let text = row[2] as? String,
                  let position = row[3] as? Int64,
                  let path = row[4] as? String else { return nil }
            let l2 = Float(distance)
            let score = max(0, 1.0 - (l2 * l2) / 2.0)
            return SearchResult(chunkId: chunkId, text: text, filePath: path,
                                corpusName: corpusName, position: Int(position), score: score)
        }
    }

    /// BM25 full-text search over chunk text. Pass `corpusId` to scope to one corpus,
    /// or `nil` to search every corpus (the FTS index is shared across all corpora).
    /// `score` holds the negated BM25 rank (larger = better); it is only meaningful for
    /// ordering within this list and is intended to be fused via RRF, not compared to cosine.
    public func lexicalSearch(query: String, corpusId: Int64?, topK: Int) throws -> [SearchResult] {
        let match = Database.ftsMatchQuery(from: query)
        guard !match.isEmpty else { return [] }

        var sql = """
            SELECT c.id, bm25(chunks_fts) AS rank, c.text, c.position, f.path, co.name
            FROM chunks_fts
            JOIN chunks c ON c.id = chunks_fts.rowid
            JOIN files f ON f.id = c.file_id
            JOIN corpora co ON co.id = f.corpus_id
            WHERE chunks_fts MATCH ?
            """
        var bindings: [Binding?] = [match]
        if let corpusId {
            sql += " AND f.corpus_id = ?"
            bindings.append(corpusId)
        }
        sql += " ORDER BY rank LIMIT \(topK)"

        return try connection.prepare(sql, bindings).compactMap { row -> SearchResult? in
            guard let chunkId = row[0] as? Int64,
                  let rank = row[1] as? Double,
                  let text = row[2] as? String,
                  let position = row[3] as? Int64,
                  let path = row[4] as? String,
                  let name = row[5] as? String else { return nil }
            // bm25() returns a negative score (more negative = better); flip for readability.
            return SearchResult(chunkId: chunkId, text: text, filePath: path,
                                corpusName: name, position: Int(position), score: Float(-rank))
        }
    }

    /// Reciprocal Rank Fusion. Combines ranked result lists by summing `1/(k + rank)` across
    /// lists (rank is 1-based). Needs no score normalization, so it cleanly merges cosine and
    /// BM25 rankings. The returned `score` is the RRF score. With a single non-empty list it
    /// just truncates to `topK`.
    public static func reciprocalRankFusion(
        _ lists: [[SearchResult]], topK: Int, k: Double = 60
    ) -> [SearchResult] {
        let nonEmpty = lists.filter { !$0.isEmpty }
        if nonEmpty.isEmpty { return [] }
        if nonEmpty.count == 1 { return Array(nonEmpty[0].prefix(topK)) }

        var scores: [Int64: Double] = [:]
        var byId: [Int64: SearchResult] = [:]
        for list in nonEmpty {
            for (idx, r) in list.enumerated() {
                scores[r.chunkId, default: 0] += 1.0 / (k + Double(idx + 1))
                if byId[r.chunkId] == nil { byId[r.chunkId] = r }
            }
        }
        return scores.sorted { $0.value > $1.value }.prefix(topK).compactMap { id, score in
            guard let r = byId[id] else { return nil }
            return SearchResult(chunkId: r.chunkId, text: r.text, filePath: r.filePath,
                                corpusName: r.corpusName, position: r.position, score: Float(score))
        }
    }

    /// Builds a safe FTS5 MATCH expression from a free-text query: splits on non-alphanumeric
    /// characters (Unicode-aware, so Cyrillic and Serbian Latin survive), quotes each term as a
    /// string literal, and ORs them together for recall. Returns "" when no usable terms remain.
    static func ftsMatchQuery(from query: String) -> String {
        let terms = query
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return "" }
        return terms
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: " OR ")
    }

    // MARK: - Helpers

    /// Parses SQLite's CURRENT_TIMESTAMP format ("YYYY-MM-DD HH:MM:SS").
    private func sqliteDate(from str: String) -> Date {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.date(from: str) ?? Date()
    }
}
