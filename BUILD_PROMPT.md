# Build Prompt — `ragmac`

Build a macOS RAG CLI tool in Swift called **`ragmac`**. Read `CLAUDE.md` in this repo first — it contains the architecture, conventions, and design decisions you must follow. This document is the one-shot build instruction: what to scaffold, in what order, and what "done" looks like for the initial version.

## Deliverable

A single Swift binary `ragmac` that:
- Indexes documents into a local SQLite + sqlite-vec database
- Embeds text using either macOS native (`NLEmbedding`) or CoreML models from HuggingFace
- Exposes read-only search capabilities via MCP stdio protocol
- Builds clean with `swift build -c release` on macOS 13+

## Project Scaffolding

Create this exact structure:

```
ragmac/
  Package.swift
  CLAUDE.md                    # already exists — do not overwrite
  README.md                    # generate based on CLAUDE.md
  .gitignore
  Sources/ragmac/
    main.swift
    Commands/
      RootCommand.swift
      CorpusCommand.swift      # create, list, delete, info subcommands
      IndexCommand.swift       # add, remove, list, refresh subcommands
      SearchCommand.swift
      MCPCommand.swift
    Core/
      Database.swift
      VecExtension.swift       # downloads + loads sqlite-vec dylib
      Embedder.swift           # protocol
      NativeEmbedder.swift
      CoreMLEmbedder.swift
      HuggingFaceEmbedder.swift
      ModelResolver.swift      # parses --model spec, dispatches to right embedder
      Chunker.swift
      Converter.swift          # file → plain text dispatch
      Converters/
        TextConverter.swift
        MarkdownConverter.swift
        HTMLConverter.swift
        PDFConverter.swift
        EPUBConverter.swift
        DOCXConverter.swift
      MCPServer.swift
      JSONRPC.swift
    Models/
      Corpus.swift
      Chunk.swift
      IndexedFile.swift
      ModelInfo.swift
  Tests/ragmacTests/
    ChunkerTests.swift
    ConverterTests.swift
    DatabaseTests.swift
```

## Implementation Order

Do not deviate from this order. Each step must be working and verifiable before moving on.

1. **`Package.swift`** with dependencies (see CLAUDE.md → Dependencies)
2. **`VecExtension.swift`** — first-run download + cache of sqlite-vec dylib for current arch
3. **`Database.swift`** — schema creation, migrations, per-corpus vector tables
4. **`NativeEmbedder.swift`** — wrap `NLEmbedding.sentenceEmbedding(for: .english)`, this is the default
5. **`Converter.swift` + all converters** — file extension → plain text
6. **`Chunker.swift`** — paragraph-aware splitting, 512-token chunks, 10% overlap
7. **`CorpusCommand.swift`** with `create` working end-to-end using native embedder
8. **`IndexCommand.swift`** — `add`, `list`, `remove`, `refresh`
9. **`SearchCommand.swift`** — single-corpus search first, then `--corpus all` handling
10. **`CoreMLEmbedder.swift`** — load `.mlpackage` from local path
11. **`HuggingFaceEmbedder.swift`** — HF Hub API integration, coreml tag validation, download, cache
12. **`JSONRPC.swift` + `MCPServer.swift`** — stdio JSON-RPC 2.0 with the three read-only tools
13. **Tests** for Chunker, Converter (per format), Database
14. **`README.md`** — user-facing quickstart

## Per-Step Acceptance Criteria

You must verify each step works before the next:

- **Step 3:** `swift run ragmac corpus list` runs without error on a fresh DB and prints "No corpora yet."
- **Step 7:** `ragmac corpus create test --description "test"` creates a corpus; `ragmac corpus list` shows it.
- **Step 8:** `ragmac index add ./README.md --corpus test` reports chunks indexed; `ragmac index list --corpus test` shows the file.
- **Step 9:** `ragmac search "build instructions" --corpus test` returns ranked chunks.
- **Step 11:** `ragmac corpus create bge --model hf:BAAI/bge-small-en-v1.5-coreml` downloads and validates the model (or fails clearly if no coreml tag).
- **Step 12:** A test MCP client sending `initialize` then `tools/list` gets the three tools; `tools/call search` returns valid results.

## Quality Bar

- Zero warnings on `swift build -c release`
- No force unwraps outside test files
- All public types and methods documented with `///` comments
- All errors thrown as typed `RagmacError` enum with localized descriptions
- Async/await throughout — no callbacks, no `DispatchQueue.async` except where required by framework boundary

## Out of Scope for v1

Do NOT implement these — they are explicitly deferred:
- Write operations (add/remove) via MCP
- Cross-model search merging
- Re-ranking
- Hybrid search (vector + keyword)
- Watch mode for auto-reindex
- Multi-language NLEmbedding selection (English only for v1)
- Encryption of the DB

## When You Finish

Output a short summary: what was built, what was deferred, any decisions you made where CLAUDE.md was ambiguous (so I can codify them).
