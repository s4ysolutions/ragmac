import ArgumentParser
import Foundation

/// Start the MCP stdio server for use by Claude and other agents.
public struct MCPCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Start JSON-RPC 2.0 MCP stdio server (read-only search tools)."
    )

    @OptionGroup var globals: GlobalOptions

    public init() {}

    public mutating func run() throws {
        let globals = self.globals
        try runAsync {
            let db = try await openDatabase(globals: globals)
            let server = MCPServer(db: db)
            await server.run()
        }
    }
}
