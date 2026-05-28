import ArgumentParser
import Foundation

/// Manage corpora (create, list, delete, info).
public struct CorpusCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "corpus",
        abstract: "Manage document corpora.",
        subcommands: [Create.self, List.self, Delete.self, Info.self]
    )

    public init() {}

    // MARK: - Create

    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a new corpus.")

        @OptionGroup var globals: GlobalOptions
        @Argument(help: "Corpus name.") var name: String
        @Option(name: .long, help: "Human-readable description.") var description: String?
        @Option(name: .long, help: "Embedding model spec (native, hf:<repo-id>, local:<path>).")
        var model: String = "native"
        @Option(name: .long, help: "Output format (text|json).") var format: String = "text"

        mutating func run() throws {
            let name = self.name
            let description = self.description
            let model = self.model
            let format = self.format
            let globals = self.globals
            try runAsync {
                let db = try await openDatabase(globals: globals)
                let embedder = try await ModelResolver.resolve(model, ragmacDir: globals.ragmacDir)
                _ = try await embedder.embed("test")
                let dims = embedder.dimensions
                let modelInfo = try db.upsertModel(source: embedder.source,
                                                   identifier: embedder.identifier,
                                                   dimensions: dims)
                let corpus = try db.createCorpus(name: name, description: description, modelId: modelInfo.id)
                try db.createVectorTable(corpusId: corpus.id, dimensions: dims)
                if format == "json" {
                    let out = ["id": corpus.id, "name": corpus.name, "dimensions": dims] as [String: Any]
                    print(jsonString(out))
                } else {
                    print("✓ Created corpus '\(corpus.name)' (model: \(model), dims: \(dims))")
                }
            }
        }
    }

    // MARK: - List

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "List all corpora.")

        @OptionGroup var globals: GlobalOptions
        @Option(name: .long, help: "Output format (text|json).") var format: String = "text"

        mutating func run() throws {
            let globals = self.globals
            let format = self.format
            try runAsync {
                let db = try await openDatabase(globals: globals)
                let corpora = try db.listCorpora()
                if corpora.isEmpty { print("No corpora yet."); return }
                if format == "json" {
                    var result: [[String: Any]] = []
                    for c in corpora {
                        let stats = try db.corpusStats(id: c.id)
                        result.append(["name": c.name,
                                       "description": c.description as Any,
                                       "fileCount": stats.fileCount,
                                       "chunkCount": stats.chunkCount])
                    }
                    print(jsonString(result))
                } else {
                    for c in corpora {
                        let stats = try db.corpusStats(id: c.id)
                        let desc = c.description.map { " — \($0)" } ?? ""
                        print("• \(c.name)\(desc) [\(stats.fileCount) files, \(stats.chunkCount) chunks]")
                    }
                }
            }
        }
    }

    // MARK: - Delete

    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "delete",
                                                        abstract: "Delete a corpus and all its data.")

        @OptionGroup var globals: GlobalOptions
        @Argument(help: "Corpus name.") var name: String

        mutating func run() throws {
            let name = self.name
            let globals = self.globals
            try runAsync {
                let db = try await openDatabase(globals: globals)
                guard let corpus = try db.fetchCorpus(name: name) else {
                    throw RagmacError.corpusNotFound(name)
                }
                try db.deleteCorpus(id: corpus.id)
                print("✓ Deleted corpus '\(name)'")
            }
        }
    }

    // MARK: - Info

    struct Info: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "info", abstract: "Show corpus details.")

        @OptionGroup var globals: GlobalOptions
        @Argument(help: "Corpus name.") var name: String
        @Option(name: .long, help: "Output format (text|json).") var format: String = "text"

        mutating func run() throws {
            let name = self.name
            let globals = self.globals
            let format = self.format
            try runAsync {
                let db = try await openDatabase(globals: globals)
                guard let corpus = try db.fetchCorpus(name: name) else {
                    throw RagmacError.corpusNotFound(name)
                }
                let model = try db.fetchModel(id: corpus.modelId)
                let stats = try db.corpusStats(id: corpus.id)
                if format == "json" {
                    let out: [String: Any] = [
                        "name": corpus.name,
                        "description": corpus.description as Any,
                        "model": model?.identifier ?? "unknown",
                        "dimensions": model?.dimensions ?? 0,
                        "fileCount": stats.fileCount,
                        "chunkCount": stats.chunkCount,
                    ]
                    print(jsonString(out))
                } else {
                    print("Corpus: \(corpus.name)")
                    if let d = corpus.description { print("  Description: \(d)") }
                    print("  Model:       \(model?.source.rawValue ?? "?"): \(model?.identifier ?? "unknown")")
                    print("  Dimensions:  \(model?.dimensions ?? 0)")
                    print("  Files:       \(stats.fileCount)")
                    print("  Chunks:      \(stats.chunkCount)")
                }
            }
        }
    }
}

func jsonString(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: .prettyPrinted),
          let str = String(data: data, encoding: .utf8) else { return "{}" }
    return str
}
