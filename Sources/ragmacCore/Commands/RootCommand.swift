import ArgumentParser
import Foundation

/// Global options available on every subcommand.
public struct GlobalOptions: ParsableArguments {
    @Option(name: .long, help: "SQLite database path (overrides RAGMAC_DB env var).")
    public var db: String?

    @Flag(name: .long, help: "Suppress progress output.")
    public var quiet: Bool = false

    @Flag(name: .long, help: "Print extra detail.")
    public var verbose: Bool = false

    public init() {}

    /// Resolved database path.
    public var resolvedDBPath: String {
        if let p = db { return p }
        if let p = ProcessInfo.processInfo.environment["RAGMAC_DB"] { return p }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ragmac/index.db").path
    }

    /// Ragmac home directory (~/.ragmac or the directory containing the DB).
    public var ragmacDir: URL {
        URL(fileURLWithPath: resolvedDBPath).deletingLastPathComponent()
    }
}

/// ragmac — local document indexing and semantic search.
public struct RootCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "ragmac",
        abstract: "Local document indexing and semantic search.",
        subcommands: [CorpusCommand.self, IndexCommand.self, SearchCommand.self, MCPCommand.self]
    )

    public init() {}
}

// MARK: - Database helper

/// Opens the database, ensuring sqlite-vec is loaded.
/// Falls back to .ragmac/ in the current directory when the primary path
/// is not writable (e.g. running under MCP sandbox).
public func openDatabase(globals: GlobalOptions) async throws -> Database {
    do {
        let vecDylib = try await VecExtension.ensureAvailable(in: globals.ragmacDir)
        return try Database(path: globals.resolvedDBPath, vecDylibPath: vecDylib.path)
    } catch {
        // Only fall back when the primary path wasn't explicitly set by the user
        let isDefault = globals.db == nil && ProcessInfo.processInfo.environment["RAGMAC_DB"] == nil
        guard isDefault else { throw error }

        let fallbackDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".ragmac")
        fputs("→ Primary path not writable, using \(fallbackDir.path)\n", stderr)
        let vecDylib = try await VecExtension.ensureAvailable(in: fallbackDir)
        let fallbackDB = fallbackDir.appendingPathComponent("index.db").path
        return try Database(path: fallbackDB, vecDylibPath: vecDylib.path)
    }
}
