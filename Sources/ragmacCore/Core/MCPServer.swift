import Foundation

/// JSON-RPC 2.0 MCP stdio server exposing read-only search tools.
public final class MCPServer {
    private let db: Database

    public init(db: Database) {
        self.db = db
    }

    public func run() async {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []

        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            let response = await handle(line: line)
            if let data = try? encoder.encode(response),
               let str = String(data: data, encoding: .utf8) {
                print(str)
                fflush(stdout)
            }
        }
    }

    private func handle(line: String) async -> JSONRPCResponse {
        guard let data = line.data(using: .utf8) else {
            return JSONRPCResponse(id: nil, error: .parseError)
        }
        let request: JSONRPCRequest
        do {
            request = try JSONDecoder().decode(JSONRPCRequest.self, from: data)
        } catch {
            return JSONRPCResponse(id: nil, error: .parseError)
        }

        switch request.method {
        case "initialize":
            return handleInitialize(id: request.id)
        case "tools/list":
            return handleToolsList(id: request.id)
        case "tools/call":
            return await handleToolsCall(id: request.id, params: request.params)
        default:
            return JSONRPCResponse(id: request.id, error: .methodNotFound)
        }
    }

    // MARK: - Handlers

    private func handleInitialize(id: JSONRPCId?) -> JSONRPCResponse {
        let result: [String: Any] = [
            "protocolVersion": "2024-11-05",
            "capabilities": ["tools": [:]],
            "serverInfo": ["name": "ragmac", "version": "1.0.0"],
        ]
        return JSONRPCResponse(id: id, result: AnyCodable(result))
    }

    private func handleToolsList(id: JSONRPCId?) -> JSONRPCResponse {
        let tools: [[String: Any]] = [
            [
                "name": "list_corpora",
                "description": "List all available document corpora with their descriptions and file counts. ALWAYS call this first to discover what knowledge is available and choose the most relevant corpus before searching. Each corpus has a focused topic indicated by its description.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "required": [] as [String],
                ],
            ],
            [
                "name": "search",
                "description": "Semantic search over an indexed corpus. Returns the most relevant text chunks ranked by similarity. Call list_corpora first to identify the best corpus for your query. Each result includes the source file path and chunk position so you can cite it.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "The search query"],
                        "corpus": ["type": "string", "description": "Corpus name to search"],
                        "top_k": ["type": "integer", "description": "Number of results (default 5, max 50)"],
                    ] as [String: Any],
                    "required": ["query", "corpus"],
                ],
            ],
            [
                "name": "list_files",
                "description": "List all files indexed in a specific corpus. Useful for understanding what source material the corpus contains before searching, or to verify a specific document is indexed.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "corpus": ["type": "string", "description": "Corpus name"],
                    ] as [String: Any],
                    "required": ["corpus"],
                ],
            ],
        ]
        return JSONRPCResponse(id: id, result: AnyCodable(["tools": tools]))
    }

    private func handleToolsCall(id: JSONRPCId?, params: JSONRPCParams?) async -> JSONRPCResponse {
        guard let toolName = params?["name"]?.value as? String else {
            return JSONRPCResponse(id: id, error: .invalidParams)
        }
        let args = (params?["arguments"]?.value as? [String: Any]) ?? [:]

        do {
            let content: Any
            switch toolName {
            case "list_corpora":
                content = try listCorpora()
            case "search":
                content = try await search(args: args)
            case "list_files":
                content = try listFiles(args: args)
            default:
                return JSONRPCResponse(id: id, error: .methodNotFound)
            }
            let result: [String: Any] = ["content": [["type": "text", "text": content]]]
            return JSONRPCResponse(id: id, result: AnyCodable(result))
        } catch {
            return JSONRPCResponse(id: id, error: .internalError(error.localizedDescription))
        }
    }

    // MARK: - Tool implementations

    private func listCorpora() throws -> String {
        let corpora = try db.listCorpora()
        if corpora.isEmpty { return "No corpora available." }
        var lines: [String] = []
        for corpus in corpora {
            let stats = try db.corpusStats(id: corpus.id)
            lines.append("• \(corpus.name): \(corpus.description ?? "(no description)") [\(stats.fileCount) files, \(stats.chunkCount) chunks]")
        }
        return lines.joined(separator: "\n")
    }

    private func search(args: [String: Any]) async throws -> String {
        guard let query = args["query"] as? String,
              let corpusName = args["corpus"] as? String else {
            throw RagmacError.mcpProtocolError(message: "search requires 'query' and 'corpus'")
        }
        let topK = min((args["top_k"] as? Int) ?? 5, 50)

        guard let corpus = try db.fetchCorpus(name: corpusName) else {
            throw RagmacError.corpusNotFound(corpusName)
        }
        guard let model = try db.fetchModel(id: corpus.modelId) else {
            throw RagmacError.modelLoadFailed(reason: "Model for corpus '\(corpusName)' not found")
        }

        let ragmacDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ragmac")
        let embedder = try await ModelResolver.resolve(
            "\(model.source.rawValue == "native" ? "native" : "\(model.source.rawValue):\(model.identifier)")",
            ragmacDir: ragmacDir
        )

        let queryVec = try await embedder.embed(query)
        let results = try db.search(corpusId: corpus.id, corpusName: corpusName, queryEmbedding: queryVec, topK: topK)

        if results.isEmpty { return "No results found." }

        var lines: [String] = []
        for (i, r) in results.enumerated() {
            lines.append("[\(i + 1)] \(r.filePath) (score: \(String(format: "%.3f", r.score)))")
            lines.append(r.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func listFiles(args: [String: Any]) throws -> String {
        guard let corpusName = args["corpus"] as? String else {
            throw RagmacError.mcpProtocolError(message: "list_files requires 'corpus'")
        }
        guard let corpus = try db.fetchCorpus(name: corpusName) else {
            throw RagmacError.corpusNotFound(corpusName)
        }
        let files = try db.listFiles(corpusId: corpus.id)
        if files.isEmpty { return "No files indexed in corpus '\(corpusName)'." }
        return files.map { "• \($0.path) (\($0.chunkCount) chunks)" }.joined(separator: "\n")
    }
}
