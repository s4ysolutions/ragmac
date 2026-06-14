import ArgumentParser
import Foundation

/// Manage indexed files within a corpus.
public struct IndexCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "index",
        abstract: "Manage indexed documents.",
        subcommands: [Add.self, Remove.self, Rename.self, List.self, Refresh.self]
    )

    public init() {}

    // MARK: - Add

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "add", abstract: "Index a file or directory.")

        @OptionGroup var globals: GlobalOptions
        @Argument(help: "File or directory path.") var path: String
        @Option(name: .long, help: "Target corpus name.") var corpus: String
        @Option(name: .long, help: "Output format (text|json).") var format: String = "text"

        mutating func run() throws {
            let path = self.path
            let corpus = self.corpus
            let format = self.format
            let globals = self.globals
            try runAsync {
                let db = try await openDatabase(globals: globals)
                guard let corp = try db.fetchCorpus(name: corpus) else {
                    throw RagmacError.corpusNotFound(corpus)
                }
                guard let modelInfo = try db.fetchModel(id: corp.modelId) else {
                    throw RagmacError.modelLoadFailed(reason: "Model for corpus '\(corpus)' not found in DB")
                }
                let embedder = try await ModelResolver.resolve(modelSpec(from: modelInfo),
                                                               ragmacDir: globals.ragmacDir)
                let absPath = URL(fileURLWithPath: path).standardizedFileURL.path
                let count = try await indexPath(absPath, corpusId: corp.id, db: db,
                                                embedder: embedder, quiet: globals.quiet)
                if format == "json" {
                    print(jsonString(["path": absPath, "chunks": count]))
                } else {
                    print("✓ Indexed \(absPath) — \(count) chunks")
                }
            }
        }
    }

    // MARK: - Remove

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "remove",
                                                        abstract: "Remove a file from the index.")

        @OptionGroup var globals: GlobalOptions
        @Argument(help: "File path.") var path: String
        @Option(name: .long, help: "Corpus name.") var corpus: String

        mutating func run() throws {
            let path = self.path
            let corpus = self.corpus
            let globals = self.globals
            try runAsync {
                let db = try await openDatabase(globals: globals)
                guard let corp = try db.fetchCorpus(name: corpus) else {
                    throw RagmacError.corpusNotFound(corpus)
                }
                let absPath = URL(fileURLWithPath: path).standardizedFileURL.path
                guard let file = try db.fetchFile(corpusId: corp.id, path: absPath) else {
                    throw RagmacError.systemError("File '\(path)' is not indexed in corpus '\(corpus)'.")
                }
                try db.deleteFile(id: file.id, corpusId: corp.id)
                print("✓ Removed \(absPath) from '\(corpus)'")
            }
        }
    }

    // MARK: - Rename

    struct Rename: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "rename",
                                                        abstract: "Rename an indexed file's path reference.")

        @OptionGroup var globals: GlobalOptions
        @Option(name: .long, help: "Corpus name.") var corpus: String
        @Option(name: .long, help: "Current file path.") var path: String
        @Option(name: .long, help: "New file path.") var newPath: String

        mutating func run() throws {
            let corpus = self.corpus
            let path = self.path
            let newPath = self.newPath
            let globals = self.globals
            try runAsync {
                let db = try await openDatabase(globals: globals)
                guard let corp = try db.fetchCorpus(name: corpus) else {
                    throw RagmacError.corpusNotFound(corpus)
                }
                let absPath = URL(fileURLWithPath: path).standardizedFileURL.path
                let absNewPath = URL(fileURLWithPath: newPath).standardizedFileURL.path
                guard let file = try db.fetchFile(corpusId: corp.id, path: absPath) else {
                    throw RagmacError.systemError("File '\(path)' is not indexed in corpus '\(corpus)'.")
                }
                try db.connection.run("UPDATE files SET path = ? WHERE id = ?", absNewPath, file.id)
                print("✓ Renamed '\(path)' → '\(newPath)'")
            }
        }
    }

    // MARK: - List

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "List indexed files.")

        @OptionGroup var globals: GlobalOptions
        @Option(name: .long, help: "Corpus name.") var corpus: String
        @Option(name: .long, help: "Output format (text|json).") var format: String = "text"

        mutating func run() throws {
            let corpus = self.corpus
            let format = self.format
            let globals = self.globals
            try runAsync {
                let db = try await openDatabase(globals: globals)
                guard let corp = try db.fetchCorpus(name: corpus) else {
                    throw RagmacError.corpusNotFound(corpus)
                }
                let files = try db.listFiles(corpusId: corp.id)
                if files.isEmpty { print("No files indexed in '\(corpus)'."); return }
                if format == "json" {
                    let out = files.map { ["path": $0.path, "chunks": $0.chunkCount] }
                    print(jsonString(out))
                } else {
                    for f in files { print("• \(f.path) (\(f.chunkCount) chunks)") }
                }
            }
        }
    }

    // MARK: - Refresh

    struct Refresh: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "refresh",
                                                        abstract: "Re-index files that have changed on disk.")

        @OptionGroup var globals: GlobalOptions
        @Option(name: .long, help: "Corpus name.") var corpus: String

        mutating func run() throws {
            let corpus = self.corpus
            let globals = self.globals
            try runAsync {
                let db = try await openDatabase(globals: globals)
                guard let corp = try db.fetchCorpus(name: corpus) else {
                    throw RagmacError.corpusNotFound(corpus)
                }
                guard let modelInfo = try db.fetchModel(id: corp.modelId) else {
                    throw RagmacError.modelLoadFailed(reason: "Model for corpus '\(corpus)' not found")
                }
                let embedder = try await ModelResolver.resolve(modelSpec(from: modelInfo),
                                                               ragmacDir: globals.ragmacDir)
                let files = try db.listFiles(corpusId: corp.id)
                var refreshed = 0
                var removed = 0
                for file in files {
                    let fm = FileManager.default
                    guard fm.fileExists(atPath: file.path) else {
                        try db.deleteFile(id: file.id, corpusId: corp.id)
                        removed += 1
                        if !globals.quiet { fputs("⚠ Removed missing: \(file.path)\n", stderr) }
                        continue
                    }
                    let attrs = try fm.attributesOfItem(atPath: file.path)
                    let currentMtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                    guard currentMtime > file.mtime else { continue }
                    if !globals.quiet { fputs("→ Re-indexing \(file.path)\n", stderr) }
                    _ = try await indexPath(file.path, corpusId: corp.id, db: db,
                                            embedder: embedder, quiet: globals.quiet)
                    refreshed += 1
                }
                print("✓ Refresh complete: \(refreshed) updated, \(removed) removed")
            }
        }
    }
}

// MARK: - Shared helpers

/// Indexes all content at path into the given corpus. Returns total chunk count.
func indexPath(
    _ absPath: String,
    corpusId: Int64,
    db: Database,
    embedder: any Embedder,
    quiet: Bool
) async throws -> Int {
    let result = try Converter.convertAll(path: absPath)
    for warning in result.warnings { fputs("\(warning)\n", stderr) }
    if !result.skipped.isEmpty && !quiet {
        fputs("⚠ Skipped \(result.skipped.count) unsupported file(s)\n", stderr)
    }

    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
        fputs("⚠ No indexable content at \(absPath)\n", stderr)
        return 0
    }

    let fm = FileManager.default
    let attrs = (try? fm.attributesOfItem(atPath: absPath)) ?? [:]
    let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    let size = (attrs[.size] as? Int64) ?? 0

    let file = try db.upsertFile(corpusId: corpusId, path: absPath, mtime: mtime, size: size)

    let oldIds = try db.connection.prepare(
        "SELECT id FROM chunks WHERE file_id = ?", file.id
    ).compactMap { $0[0] as? Int64 }
    for cid in oldIds {
        try db.connection.run("DELETE FROM chunk_embeddings_\(corpusId) WHERE chunk_id = ?", cid)
    }
    try db.connection.run("DELETE FROM chunks WHERE file_id = ?", file.id)

    let chunks = Chunker.chunk(text, for: embedder)
    if !quiet { fputs("→ Embedding \(chunks.count) chunks ", stderr) }

    let embeddings = try await embedChunks(chunks, embedder: embedder, quiet: quiet)
    let chunkIds = try db.insertChunks(chunks, fileId: file.id)
    try db.insertEmbeddings(corpusId: corpusId, chunkIds: chunkIds, embeddings: embeddings)
    try db.updateFileChunkCount(fileId: file.id, count: chunks.count)

    return chunks.count
}

func embedChunks(_ chunks: [ChunkContent], embedder: any Embedder, quiet: Bool) async throws -> [[Float]] {
    let total = chunks.count
    let batchSize = 16
    var embeddings: [[Float]] = []
    embeddings.reserveCapacity(total)

    for i in stride(from: 0, to: total, by: batchSize) {
        let end = min(i + batchSize, total)
        let batch = Array(chunks[i..<end])
        let batchEmbeddings = try await embedder.embedBatch(batch.map { $0.text })
        embeddings.append(contentsOf: batchEmbeddings)
        if !quiet {
            let pct = (end * 100) / total
            fputs("\r→ Embedding \(end)/\(total) chunks (\(pct)%)", stderr)
        }
    }
    if !quiet { fputs("\n", stderr) }
    return embeddings
}

func modelSpec(from info: ModelInfo) -> String {
    switch info.source {
    case .native: return "native"
    case .hf: return "hf:\(info.identifier)"
    case .local: return "local:\(info.identifier)"
    }
}
