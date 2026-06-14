import ArgumentParser
import Foundation

/// Manage embedding models.
public struct ModelCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "model",
        abstract: "Manage embedding models.",
        subcommands: [List.self]
    )

    public init() {}

    // MARK: - List

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "List downloaded models.")

        @OptionGroup var globals: GlobalOptions
        @Option(name: .long, help: "Output format (text|json).") var format: String = "text"

        mutating func run() throws {
            let format = self.format
            let globals = self.globals
            try runAsync {
                let db = try await openDatabase(globals: globals)
                let models = try db.connection.prepare(
                    """
                    SELECT m.id, m.source, m.identifier, m.dimensions, COUNT(c.id) as usage_count
                    FROM models m
                    LEFT JOIN corpora c ON m.id = c.model_id
                    GROUP BY m.id
                    ORDER BY m.source, m.identifier
                    """
                ).map { row -> (Int64, String, String, Int, Int) in
                    (row[0] as! Int64, row[1] as! String, row[2] as! String, Int(row[3] as! Int64), Int(row[4] as! Int64))
                }

                if models.isEmpty {
                    print("No models found.")
                    return
                }

                if format == "json" {
                    let out = models.map { id, source, identifier, dimensions, usage in
                        [
                            "id": String(id),
                            "source": source,
                            "identifier": identifier,
                            "dimensions": String(dimensions),
                            "usage": String(usage)
                        ]
                    }
                    print(jsonString(out))
                } else {
                    print("Models:")
                    for (_, source, identifier, dimensions, usage) in models {
                        let spec: String
                        switch source {
                        case "native":
                            spec = "native"
                        case "hf":
                            spec = "hf:\(identifier)"
                        case "local":
                            spec = "local:\(identifier)"
                        default:
                            spec = identifier
                        }
                        let usageStr = usage > 0 ? " (\(usage) corpus/corpora)" : ""
                        print("  • \(spec) — \(dimensions)d\(usageStr)")
                    }
                }
            }
        }
    }
}
