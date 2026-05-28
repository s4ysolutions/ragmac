import ArgumentParser
import Foundation

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

    public init() {}

    public mutating func run() throws {
        let query = self.query
        let corpus = self.corpus
        let topK = self.topK
        let format = self.format
        let globals = self.globals
        try runAsync {
            let db = try await openDatabase(globals: globals)
            if corpus == "all" {
                try await searchAll(db: db, query: query, topK: topK, format: format,
                                    globals: globals)
            } else {
                try await searchOne(db: db, corpusName: corpus, query: query, topK: topK,
                                    format: format, globals: globals)
            }
        }
    }
}

private func searchOne(
    db: Database, corpusName: String, query: String, topK: Int, format: String,
    globals: GlobalOptions
) async throws {
    guard let corp = try db.fetchCorpus(name: corpusName) else {
        throw RagmacError.corpusNotFound(corpusName)
    }
    guard let modelInfo = try db.fetchModel(id: corp.modelId) else {
        throw RagmacError.modelLoadFailed(reason: "Model for corpus '\(corpusName)' not found")
    }
    let embedder = try await ModelResolver.resolve(modelSpec(from: modelInfo), ragmacDir: globals.ragmacDir)
    let queryVec = try await embedder.embed(query)
    let results = try db.search(corpusId: corp.id, corpusName: corpusName,
                                queryEmbedding: queryVec, topK: topK)
    printResults(results, format: format)
}

private func searchAll(
    db: Database, query: String, topK: Int, format: String, globals: GlobalOptions
) async throws {
    let corpora = try db.listCorpora()
    guard !corpora.isEmpty else { print("No corpora to search."); return }

    let modelIds = Set(corpora.map { $0.modelId })

    if modelIds.count == 1 {
        guard let modelInfo = try db.fetchModel(id: modelIds.first!) else {
            throw RagmacError.modelLoadFailed(reason: "Model not found")
        }
        let embedder = try await ModelResolver.resolve(modelSpec(from: modelInfo),
                                                       ragmacDir: globals.ragmacDir)
        let queryVec = try await embedder.embed(query)
        var allResults: [Database.SearchResult] = []
        for corp in corpora {
            allResults.append(contentsOf: try db.search(corpusId: corp.id, corpusName: corp.name,
                                                        queryEmbedding: queryVec, topK: topK))
        }
        let merged = Array(allResults.sorted { $0.score > $1.score }.prefix(topK))
        printResults(merged, format: format)
    } else {
        if format != "json" {
            fputs("⚠ Corpora use different models; results grouped by corpus (no global ranking)\n", stderr)
        }
        var grouped: [[String: Any]] = []
        for corp in corpora {
            guard let modelInfo = try db.fetchModel(id: corp.modelId) else { continue }
            let embedder = try await ModelResolver.resolve(modelSpec(from: modelInfo),
                                                           ragmacDir: globals.ragmacDir)
            let queryVec = try await embedder.embed(query)
            let results = try db.search(corpusId: corp.id, corpusName: corp.name,
                                        queryEmbedding: queryVec, topK: topK)
            if format == "json" {
                grouped.append(["corpus": corp.name, "results": resultsToDict(results)])
            } else if !results.isEmpty {
                print("\n── \(corp.name) ──")
                printResults(results, format: format)
            }
        }
        if format == "json" { print(jsonString(grouped)) }
    }
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
