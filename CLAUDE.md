# CLAUDE.md — `ragmac` Project Knowledge

This file is the durable source of truth for the `ragmac` codebase. Read it at the start of every session. It explains *why* things are the way they are, not just *what* they are.

## What `ragmac` Is

A macOS-native command-line RAG (retrieval-augmented generation) tool. It indexes local documents, generates embeddings via either Apple's `NaturalLanguage.framework` or CoreML models, stores vectors in SQLite, and exposes search over MCP for use by Claude and other agents.

**Design ethos:** zero external dependencies at runtime when possible. Native frameworks first. Downloaded models second. Never Python or Node.

## Architecture

### Stack
- **Language:** Swift 5.9+, targets macOS 13+
- **CLI parser:** `swift-argument-parser`
- **Database:** SQLite via `SQLite.swift`, with [`sqlite-vec`](https://github.com/asg017/sqlite-vec) loaded as a runtime extension
- **Embeddings:** `NLEmbedding` (native) or CoreML via `CoreML.framework`
- **HTTP:** `URLSession` (for HuggingFace Hub API and model downloads)

### Storage Layout
```
~/.ragmac/
  index.db          # SQLite database (override via --db or RAGMAC_DB env)
  vec0.dylib        # sqlite-vec extension, downloaded on first run
  models/           # Cached CoreML models
    <repo-id>/      # One directory per HF repo
```

### Database Schema

```sql
CREATE TABLE models (
  id INTEGER PRIMARY KEY,
  source TEXT NOT NULL,        -- 'native' | 'hf' | 'local'
  identifier TEXT NOT NULL,    -- e.g. 'native', 'BAAI/bge-small-en-v1.5-coreml', '/path/to/model.mlpackage'
  dimensions INTEGER NOT NULL,
  UNIQUE(source, identifier)
);

CREATE TABLE corpora (
  id INTEGER PRIMARY KEY,
  name TEXT UNIQUE NOT NULL,
  description TEXT,
  model_id INTEGER NOT NULL REFERENCES models(id),
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE files (
  id INTEGER PRIMARY KEY,
  corpus_id INTEGER NOT NULL REFERENCES corpora(id) ON DELETE CASCADE,
  path TEXT NOT NULL,          -- absolute path
  mtime REAL NOT NULL,
  size INTEGER NOT NULL,
  chunk_count INTEGER DEFAULT 0,
  indexed_at DATETIME DEFAULT CURRENT_TIMESTAMP,
  UNIQUE(corpus_id, path)
);

CREATE TABLE chunks (
  id INTEGER PRIMARY KEY,
  file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
  text TEXT NOT NULL,
  position INTEGER NOT NULL,   -- 0-based index within file
  start_offset INTEGER,        -- char offset in source text
  end_offset INTEGER
);

-- Per-corpus virtual table, created dynamically at corpus-create time.
-- Name format: chunk_embeddings_<corpus_id>
-- This is REQUIRED because sqlite-vec needs fixed dimensions per table,
-- and different corpora can use models with different dimensions.
CREATE VIRTUAL TABLE chunk_embeddings_<corpus_id> USING vec0(
  chunk_id INTEGER PRIMARY KEY,
  embedding float[<dimensions>]
);
```

### Why Per-Corpus Vector Tables

`sqlite-vec` requires fixed dimensionality per virtual table. Different embedding models have different dimensions:
- `NLEmbedding` English sentence: 512
- `all-MiniLM-L6-v2`: 384
- `BGE-small`: 384
- `BGE-large`: 1024

A single shared embeddings table cannot accommodate this. Per-corpus tables also make corpus deletion trivial (`DROP TABLE`) and prevent any chance of cross-model vector contamination.

## Embedding Models

### Three Sources

The `--model` flag accepts these forms:

| Form | Meaning | Example |
|------|---------|---------|
| `native` | macOS `NLEmbedding`, no download | `--model native` (default) |
| `hf:<repo-id>` | HuggingFace model with `coreml` tag | `--model hf:BAAI/bge-small-en-v1.5-coreml` |
| `local:<path>` | Local `.mlpackage` or `.mlmodel` | `--model local:~/models/my-embed.mlpackage` |

### HuggingFace Filter

When `--model hf:<repo-id>` is given, ragmac MUST:
1. Fetch model metadata from `https://huggingface.co/api/models/<repo-id>`
2. Verify the model has a `coreml` tag in its tags array
3. Reject with a clear error if missing — DO NOT attempt to download or convert non-CoreML models
4. Locate the `.mlpackage` or `.mlmodel` file in the repo (LFS or regular)
5. Download to `~/.ragmac/models/<repo-id>/`

This filter exists because not all transformer models convert cleanly to CoreML due to unsupported MIL ops. Trusting the `coreml` tag means we only use models that have been explicitly prepared and verified for CoreML.

### Model Validation at Corpus Create

When creating a corpus, the embedder MUST be validated before the corpus row is committed:
1. Load the embedder
2. Embed a probe string ("test")
3. Record the actual dimension count returned
4. Create corpus row and per-corpus vector table atomically

This prevents corpora with broken model references.

### Embedder Protocol

```swift
protocol Embedder: Sendable {
    var dimensions: Int { get }
    var identifier: String { get }
    var source: ModelSource { get }
    func embed(_ text: String) async throws -> [Float]
    func embedBatch(_ texts: [String]) async throws -> [[Float]]
}

enum ModelSource: String { case native, hf, local }
```

## File Conversion

All conversions are native macOS — no external binaries.

| Extension | Framework | Notes |
|-----------|-----------|-------|
| `.txt` | Foundation | Direct read with encoding detection |
| `.md` | Custom | Regex strip markdown syntax; preserve code block contents but drop fences |
| `.html`, `.htm` | `NSAttributedString(html:)` | Extract `string` property |
| `.pdf` | `PDFKit` | Iterate `PDFPage`, concatenate `string` |
| `.epub` | `Foundation` + `XMLParser` | EPUB is a zip; parse `content.opf` for spine, then XHTML files |
| `.docx` | `Foundation` + `XMLParser` | DOCX is a zip; parse `word/document.xml`, extract `<w:t>` nodes |

Unsupported extensions: skip with warning, never fail the batch. Report a summary at end of indexing operations.

## Chunking Strategy

- **Target size:** 512 tokens, approximated as 2048 characters (1 token ≈ 4 chars)
- **Overlap:** 10% (~205 chars) between adjacent chunks
- **Boundary preference:** prefer to split at paragraph breaks (`\n\n`), fall back to sentence boundaries, last resort hard char split
- **Track offsets:** every chunk records `start_offset` and `end_offset` in the original text for citation support

Chunking is intentionally simple. Do not add token-aware chunking unless absolutely necessary — the model-specific tokenizers add complexity disproportionate to the quality gain for this use case.

## CLI Conventions

### Global Flags
- `--db <path>` — override DB location (also `RAGMAC_DB` env var)
- `--quiet` — suppress progress output
- `--verbose` — extra detail

### Output
- **stdout:** primary output (search results, listings, success messages)
- **stderr:** errors, warnings, progress indicators
- **Exit codes:** 0 success, 1 user error, 2 system error
- **Format flag:** `--format json|text` (text is default), JSON for scripting

### Status Indicators
- `✓` success
- `✗` failure
- `⚠` warning
- `→` progress / in-progress

### Subcommand Map
```
ragmac corpus  create|list|delete|info
ragmac index   add|remove|list|refresh
ragmac search  <query>
ragmac mcp     (no subcommands, starts stdio server)
```

## Search Semantics

### Single Corpus (default)
`--corpus <name>` is required by default. Returns top-k chunks ranked by cosine similarity.

### Cross-Corpus
`--corpus all` is an opt-in mode with these rules:
- If ALL corpora share the same model: merge-rank results across all corpora
- If corpora use different models: return results **grouped by corpus** with no global ranking (because comparing distances across models is meaningless)

Never silently merge across different vector spaces.

### Instruction-Aware Models

Some embedding models (e.g. Qwen3-Embedding) are **asymmetric**: documents are embedded raw, but queries must carry a task instruction prefix or they land in a different region of the vector space and retrieval fails (a verbatim phrase can score worse than a random word).

`ragmac search` exposes `--query-instruction "<task>"`. When given, the query is wrapped as:
```
Instruct: <task>\nQuery: <query>
```
before embedding. Documents are NEVER prefixed, so switching this on does **not** require reindexing. Omit the flag for symmetric models (`native`).

Example:
```
ragmac search --corpus books --query-instruction "Given a search query, retrieve relevant passages" "grupa sa Krebom i Gojlom"
```

This is an explicit knob by design — no auto-detection by model identifier (too brittle), and the wrapping format is the Qwen `Instruct:/Query:` template.

### Result Format
Each result includes: text, source file path, corpus name, position, score. The score is cosine similarity (0..1).

## MCP Server

### Protocol
JSON-RPC 2.0 over stdio, newline-delimited. Implement these methods:
- `initialize` — return protocolVersion, capabilities, serverInfo
- `tools/list` — return the tool definitions
- `tools/call` — dispatch to the right tool

### Tools (read-only in v1)

**`list_corpora`** — Description must encourage the agent to call this FIRST before searching:
> "List all available document corpora with their descriptions and file counts. ALWAYS call this first to discover what knowledge is available and choose the most relevant corpus before searching. Each corpus has a focused topic indicated by its description."

**`search`** — Requires explicit corpus:
> "Semantic search over an indexed corpus. Returns the most relevant text chunks ranked by similarity. Call list_corpora first to identify the best corpus for your query. Each result includes the source file path and chunk position so you can cite it."

Input schema requires `query` and `corpus`. `top_k` defaults to 5, max 50.

**`list_files`** — Inspect what's in a corpus:
> "List all files indexed in a specific corpus. Useful for understanding what source material the corpus contains before searching, or to verify a specific document is indexed."

### Why Read-Only

Indexing is slow and has side effects. MCP tools are expected to be fast and idempotent. Exposing `add_file` over MCP also creates a security concern — an agent could be tricked into indexing unintended files. v1 keeps write operations CLI-only. Future versions may add write tools behind explicit opt-in.

## Error Handling

All errors flow through a single `RagmacError` enum:

```swift
enum RagmacError: LocalizedError {
    case corpusNotFound(String)
    case corpusAlreadyExists(String)
    case modelNotCoreML(repoId: String)
    case modelLoadFailed(reason: String)
    case unsupportedFileType(extension: String)
    case dimensionMismatch(expected: Int, got: Int)
    case databaseError(underlying: Error)
    case mcpProtocolError(message: String)
    // errorDescription provides actionable guidance
}
```

User errors get suggestions: "Corpus 'foo' not found. Run `ragmac corpus list` to see available corpora."

## Dependencies

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    .package(url: "https://github.com/stephencelis/SQLite.swift", from: "0.15.0"),
]
```

**sqlite-vec** is NOT a Swift package — it's a C extension loaded at runtime. `VecExtension.swift` downloads the prebuilt dylib from the [sqlite-vec releases](https://github.com/asg017/sqlite-vec/releases) for the current arch (arm64 or x86_64) on first run and caches it. Load via `sqlite3_load_extension`. Detect arch via `#if arch(arm64)`.

Do NOT add any other dependencies without strong justification. Native frameworks first.

## Conventions

- **Swift style:** standard Apple conventions, `swift-format` rules
- **File naming:** one type per file, filename matches type name
- **Indentation:** 4 spaces
- **Async:** prefer `async/await`, avoid Combine and callbacks
- **Errors:** throw `RagmacError`, never `fatalError` outside `main.swift`
- **Force unwraps:** banned in non-test code
- **Documentation:** every public type and method has `///` doc comments
- **Tests:** XCTest, one test file per source file under test

## Things That Look Like Bugs But Aren't

- **`NLEmbedding` returns the same vector for very different sentences.** It's a word-averaging model. This is expected. For better quality, users should switch to a CoreML model.
- **First `ragmac` run is slow.** Downloading sqlite-vec dylib (~1MB). Subsequent runs use the cached copy.
- **HuggingFace download progress reports byte counts, not percent.** Many CoreML models on HF don't expose Content-Length headers when behind LFS.

## Future / Deferred

In rough priority order:
1. Write operations over MCP (behind `--allow-write` flag)
2. Watch mode (`ragmac index watch <path>`)
3. Hybrid search (BM25 + vector)
4. Reranking with a cross-encoder
5. Non-English `NLEmbedding` languages
6. Encrypted DB option
7. Sync between machines (export/import corpora)

When implementing any of these, update this section and the relevant `## Why` section so future sessions know the reasoning.
