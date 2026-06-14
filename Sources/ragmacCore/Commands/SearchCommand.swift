import ArgumentParser
import Foundation

/// How a search query is matched against the corpus.
enum SearchMode: String, ExpressibleByArgument {
    case dense    // vector similarity only (default)
    case hybrid   // dense + BM25, fused with RRF
    case lexical  // BM25 full-text only
}

/// Search indexed corpora.
public struct SearchCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Semantic search over an indexed corpus."
    )

    @OptionGroup var globals: GlobalOptions
    @Argument(help: "Search query.") var query: String
    @Option(name: .long, help: "Corpus name ('all' searches all corpora).") var corpus: String
    @Option(name: .shortAndLong, help: "Number of results.") var topK: Int = 5
    @Option(name: .long, help: "Output format (text|json).") var format: String = "text"
    @Option(name: .long, help: "Retrieval mode (dense|hybrid|lexical). Dense is vector-only; hybrid fuses vector + BM25 via RRF.")
    var mode: SearchMode = .dense
    @Option(name: .long, help: """
        Task instruction for instruction-aware embedding models (e.g. Qwen3-Embedding). \
        The query is wrapped as "Instruct: <task>\\nQuery: <query>" before embedding. \
        Required for correct retrieval with such models; omit for symmetric models like native. \
        Affects only the dense side; BM25 always uses the raw query.
        """)
    var queryInstruction: String?

    public init() {}

    public mutating func run() throws {
        let query = self.query
        let corpus = self.corpus
        let topK = self.topK
        let format = self.format
        let mode = self.mode
        let instruction = self.queryInstruction
        let globals = self.globals
        try runAsync {
            let db = try await openDatabase(globals: globals)
            let ctx = SearchContext(query: query, topK: topK, format: format, mode: mode,
                                    instruction: instruction, globals: globals)
            if corpus == "all" {
                try await searchAll(db: db, ctx: ctx)
            } else {
                try await searchOne(db: db, corpusName: corpus, ctx: ctx)
            }
        }
    }

    /// Wraps the query in the Qwen-style instruction template when a task is given.
    /// Instruction-aware models (Qwen3-Embedding, etc.) embed queries asymmetrically:
    /// documents are embedded raw, but queries must carry a task prefix or they land in
    /// a different region of the vector space and retrieval fails.
    static func applyInstruction(_ query: String, instruction: String?) -> String {
        guard let task = instruction, !task.isEmpty else { return query }
        return "Instruct: \(task)\nQuery: \(query)"
    }
}

/// Shared parameters for a single `search` invocation.
private struct SearchContext {
    let query: String
    let topK: Int
    let format: String
    let mode: SearchMode
    let instruction: String?
    let globals: GlobalOptions

    /// Fetch this many candidates per ranked list before fusing, so RRF has room to reorder.
    var poolK: Int { max(topK, 50) }
}

private func searchOne(db: Database, corpusName: String, ctx: SearchContext) async throws {
    guard let corp = try db.fetchCorpus(name: corpusName) else {
        throw RagmacError.corpusNotFound(corpusName)
    }
    let lists = try await rankedLists(db: db, corpusId: corp.id, corpusName: corpusName, ctx: ctx)
    printResults(fuse(lists, topK: ctx.topK), format: ctx.format)
}

private func searchAll(db: Database, ctx: SearchContext) async throws {
    let corpora = try db.listCorpora()
    guard !corpora.isEmpty else { print("No corpora to search."); return }

    let modelIds = Set(corpora.map { $0.modelId })

    if modelIds.count == 1 {
        // All corpora share a model → fuse globally. The dense vector space is shared,
        // and the FTS index already spans every corpus, so a single lexical query covers all.
        guard let modelInfo = try db.fetchModel(id: modelIds.first!) else {
            throw RagmacError.modelLoadFailed(reason: "Model not found")
        }
        var lists: [[Database.SearchResult]] = []
        if ctx.mode != .lexical {
            let embedder = try await ModelResolver.resolve(modelSpec(from: modelInfo),
                                                           ragmacDir: ctx.globals.ragmacDir)
            let queryVec = try await embedder.embed(
                SearchCommand.applyInstruction(ctx.query, instruction: ctx.instruction))
            var dense: [Database.SearchResult] = []
            for corp in corpora {
                dense.append(contentsOf: try db.search(corpusId: corp.id, corpusName: corp.name,
                                                       queryEmbedding: queryVec, topK: ctx.poolK))
            }
            lists.append(Array(dense.sorted { $0.score > $1.score }.prefix(ctx.poolK)))
        }
        if ctx.mode != .dense {
            lists.append(try db.lexicalSearch(query: ctx.query, corpusId: nil, topK: ctx.poolK))
        }
        printResults(fuse(lists, topK: ctx.topK), format: ctx.format)
    } else {
        if ctx.format != "json" {
            fputs("⚠ Corpora use different models; results grouped by corpus (no global ranking)\n", stderr)
        }
        var grouped: [[String: Any]] = []
        for corp in corpora {
            let lists = try await rankedLists(db: db, corpusId: corp.id, corpusName: corp.name, ctx: ctx)
            let results = fuse(lists, topK: ctx.topK)
            if ctx.format == "json" {
                grouped.append(["corpus": corp.name, "results": resultsToDict(results)])
            } else if !results.isEmpty {
                print("\n── \(corp.name) ──")
                printResults(results, format: ctx.format)
            }
        }
        if ctx.format == "json" { print(jsonString(grouped)) }
    }
}

/// Runs the dense and/or lexical searches for one corpus per the requested mode and returns
/// each as a separate ranked list (for the caller to fuse).
private func rankedLists(
    db: Database, corpusId: Int64, corpusName: String, ctx: SearchContext
) async throws -> [[Database.SearchResult]] {
    var lists: [[Database.SearchResult]] = []
    if ctx.mode != .lexical {
        guard let corp = try db.fetchCorpus(id: corpusId),
              let modelInfo = try db.fetchModel(id: corp.modelId) else {
            throw RagmacError.modelLoadFailed(reason: "Model for corpus '\(corpusName)' not found")
        }
        let embedder = try await ModelResolver.resolve(modelSpec(from: modelInfo),
                                                       ragmacDir: ctx.globals.ragmacDir)
        let queryVec = try await embedder.embed(
            SearchCommand.applyInstruction(ctx.query, instruction: ctx.instruction))
        lists.append(try db.search(corpusId: corpusId, corpusName: corpusName,
                                   queryEmbedding: queryVec, topK: ctx.poolK))
    }
    if ctx.mode != .dense {
        lists.append(try db.lexicalSearch(query: ctx.query, corpusId: corpusId, topK: ctx.poolK))
    }
    return lists
}

/// Fuses dense and lexical ranked lists via Reciprocal Rank Fusion (see Database).
private func fuse(_ lists: [[Database.SearchResult]], topK: Int) -> [Database.SearchResult] {
    Database.reciprocalRankFusion(lists, topK: topK)
}

private func printResults(_ results: [Database.SearchResult], format: String) {
    if results.isEmpty { print("No results found."); return }
    if format == "json" { print(jsonString(resultsToDict(results))); return }
    for (i, r) in results.enumerated() {
        print("\n[\(i + 1)] \(r.filePath) (corpus: \(r.corpusName), score: \(String(format: "%.3f", r.score)))")
        print(r.text)
    }
}

private func resultsToDict(_ results: [Database.SearchResult]) -> [[String: Any]] {
    results.map { r in
        ["text": r.text, "file": r.filePath, "corpus": r.corpusName,
         "position": r.position, "score": Double(r.score)]
    }
}
