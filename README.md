# ragmac

A macOS-native command-line RAG (retrieval-augmented generation) tool. Indexes local documents, generates embeddings via Apple's `NaturalLanguage.framework` or CoreML models, stores vectors in SQLite via [sqlite-vec](https://github.com/asg017/sqlite-vec), and exposes search over MCP for Claude and other agents.

**Zero external runtime dependencies.** No Python, no Node, no servers to run.

## Why ragmac?

Existing RAG tools for MCP bring a heavy stack: Python, pip, venv, PyTorch, sentence-transformers, or cloud API keys. ragmac is one native Swift binary — no language runtime to install, no dependency tree to manage, no API keys to provision.

- **Embeddings run locally on hardware you already have.** `NLEmbedding` (free, no download) for quick indexing. CoreML models from HuggingFace run on the Neural Engine for higher-quality retrieval. No network calls, no inference services, no usage limits.
- **File conversion uses macOS frameworks.** PDFKit for PDF, NSAttributedString for HTML, XMLParser for DOCX and EPUB. No external converters.
- **Storage is a single SQLite file.** No server process, no daemon. Back it up, move it, or share it like any file.
- **MCP over stdio.** No port to expose, no auth to configure. The agent spawns the process and talks JSON-RPC over stdin/stdout.

If you're on macOS 13+ with Swift 6.1, you already have the full stack. `swift build -c release` produces a single universal binary. Copy it anywhere a Mac of the same arch — it runs.

## Requirements

- macOS 13+
- Swift 6.1+
- Xcode 16+ (or Command Line Tools for Xcode 16+)

## Build from Source

```bash
# Clone the repo
git clone <repo-url> ragmac
cd ragmac

# Verify Swift version
swift --version          # should be 6.1 or later

# Debug build (faster to compile)
swift build

# Release build (optimized, smaller binary)
swift build -c release

# Run directly from build directory
.build/release/ragmac --help

# Optional: install to PATH
cp .build/release/ragmac /usr/local/bin/ragmac
# or, if /usr/local/bin doesn't exist on your system:
sudo mkdir -p /usr/local/bin
sudo cp .build/release/ragmac /usr/local/bin/ragmac
```

The build produces a single universal binary for your native architecture (arm64 on Apple Silicon, x86_64 on Intel). No code signing or notarization needed.

### Build Troubleshooting

- **`error: cannot find 'SQLite' in scope`** — Run `swift package resolve` to fetch dependencies, then rebuild.
- **`sqlite3_enable_load_extension` linker error** — The project uses `SQLiteSwiftCSQLite` which bundles a custom sqlite3 build. Make sure the `SQLite.swift` dependency traits are correctly resolved in Package.swift.
- **Slow first build** — Normal. Swift builds the dependency graph once, then incremental builds are fast.

## Quickstart

The `samples/` directory contains two files for a hands-on walkthrough: a `.txt` overview document and a `.pdf` report.

### Step 1: Create a Corpus

```bash
# Using native NLEmbedding (default, no download needed)
ragmac corpus create mydocs --description "My document collection"

# Verify it was created
ragmac corpus list
```

Output:
```
→ Creating corpus...
✓ Corpus 'mydocs' created
Name        Description              Files  Chunks  Model
mydocs      My document collection   0      0       native (512d)
```

### Step 2: Index Sample Files

```bash
# Index the samples directory
ragmac index add ./samples/ --corpus mydocs

# Or index individual files
ragmac index add ./samples/ragmac-overview.txt --corpus mydocs
ragmac index add ./samples/report.pdf --corpus mydocs

# See what's indexed
ragmac index list --corpus mydocs
```

Output:
```
→ Indexing ./samples/ragmac-overview.txt...
✓ Indexed ragnac-overview.txt (2 chunks)
→ Indexing ./samples/report.pdf...
✓ Indexed report.pdf (1 chunk)
```

### Step 3: Search

```bash
# Semantic search across indexed documents
ragmac search "embedding models" --corpus mydocs

# Get more results
ragmac search "performance" --corpus mydocs --top-k 10

# JSON output for scripting
ragmac search "performance" --corpus mydocs --format json

# Cross-corpus search
ragmac search "performance" --corpus all
```

Output:
```
   Score  Source
→  0.823  ragnac-overview.txt (chunk 0)
   0.741  report.pdf (chunk 0)
```

### Step 4: Manage Index

```bash
# Re-index files that changed on disk
ragmac index refresh --corpus mydocs

# Remove a file from the index
ragmac index remove ./samples/report.pdf --corpus mydocs

# Delete entire corpus
ragmac corpus delete mydocs
```

## Subcommands

### `ragmac corpus`

```bash
ragmac corpus create <name> [--description <text>] [--model <spec>]
ragmac corpus list [--format json]
ragmac corpus delete <name>
ragmac corpus info <name>
```

### `ragmac index`

```bash
ragmac index add <path> --corpus <name>
ragmac index list --corpus <name>
ragmac index remove <path> --corpus <name>
ragmac index refresh --corpus <name>
```

`index add` accepts files or directories. Directories are scanned recursively. Unsupported file types are skipped with a warning — never fatal.

### `ragmac search`

```bash
ragmac search <query> --corpus <name> [--top-k 5] [--format json]
ragmac search <query> --corpus all   # search all corpora
```

### `ragmac mcp`

Starts a JSON-RPC 2.0 MCP stdio server for integration with Claude and other AI agents. See [MCP Server Configuration](#mcp-server-configuration) below.

## MCP Server Configuration

The MCP server runs over stdio and exposes three read-only tools. Claude and other MCP clients discover these tools automatically through the protocol handshake.

### Tools

| Tool | Parameters | Description |
|------|-----------|-------------|
| `list_corpora` | (none) | Lists all corpora with descriptions and file/chunk counts. Call this first to discover what's available. |
| `search` | `query` (string), `corpus` (string), `top_k` (int, default 5, max 50) | Semantic search. Returns ranked chunks with file path, position, and cosine similarity score. |
| `list_files` | `corpus` (string) | Lists all indexed file paths in a corpus. Useful before searching to verify document coverage. |

All tools are read-only by design. Indexing requires CLI use — this keeps MCP calls fast and idempotent.

### Claude Code

Add to `~/.claude/claude_tools.json` (user-scoped) or `.claude/mcp.json` (project-scoped):

```json
{
  "mcpServers": {
    "ragmac": {
      "command": "/usr/local/bin/ragmac",
      "args": ["mcp"]
    }
  }
}
```

If you installed ragmac elsewhere, adjust the `command` path. Use `which ragmac` to find it.

**Project-scoped example** (`.claude/mcp.json` in your project root):

```json
{
  "mcpServers": {
    "ragmac": {
      "command": "/usr/local/bin/ragmac",
      "args": ["mcp"],
      "env": {
        "RAGMAC_DB": "/Users/me/project/.ragmac/index.db"
      }
    }
  }
}
```

The `RAGMAC_DB` env var lets you use a project-local database instead of `~/.ragmac/index.db`.

### Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "ragmac": {
      "command": "/usr/local/bin/ragmac",
      "args": ["mcp"]
    }
  }
}
```

### Troubleshooting MCP

- **"You don't have permission to save the file" error at startup** — The MCP process runs sandboxed and cannot write to `~/.ragmac/`. Two fixes:
  1. **Pre-download** (recommended): run `ragmac corpus create test` once from a terminal before configuring MCP. This creates `~/.ragmac/` and downloads the dylib. The MCP server will use the cache without writing.
  2. **Automatic fallback**: if no explicit `--db` or `RAGMAC_DB` is set, ragmac falls back to `./.ragmac/` in the project directory when `~/.ragmac/` is not writable. Set `RAGMAC_DB` to control this explicitly.
- **Server starts but tools don't appear** — Check the MCP client logs. ragmac writes startup errors to stderr. Run `ragmac mcp` manually and type `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}` followed by a newline to test.
- **`ragmac: command not found`** — Use the full path in the config, or ensure `/usr/local/bin` is in your shell's PATH *and* the MCP client inherits it.
- **Empty search results** — Verify the corpus exists and has indexed files: `ragmac corpus list` and `ragmac index list --corpus <name>`.
- **Model download hangs** — HuggingFace CoreML models behind LFS may not report Content-Length headers. The download is still progressing; wait for it to complete.

## Embedding Models

| Spec | Source | Notes |
|------|--------|-------|
| `native` (default) | macOS `NLEmbedding` | No download, 512 dims, English only |
| `hf:<repo-id>` | HuggingFace Hub | Must have `coreml` tag |
| `local:<path>` | Local `.mlpackage` | |

```bash
# Use a HuggingFace CoreML model
ragmac corpus create bge --model hf:BAAI/bge-small-en-v1.5-coreml
```

## Supported File Types

| Extension | Converter | Notes |
|-----------|-----------|-------|
| `.txt` | `String(contentsOf:)` with encoding detection | UTF-8, Latin-1, auto-detect |
| `.md` | Regex-based markdown stripping | Preserves code block contents, strips fences |
| `.html`, `.htm` | `NSAttributedString(html:)` | Extracts plain text via attributed string |
| `.pdf` | `PDFKit` | Iterates PDFPage objects, concatenates strings |
| `.epub` | Zip + XMLParser | Parses OPF spine, extracts XHTML content |
| `.docx` | Zip + XMLParser | Extracts `<w:t>` text nodes from document.xml |

Unsupported files are skipped with a warning; they never fail a batch. The indexing summary reports skip counts.

## Storage

```
~/.ragmac/
  index.db          # SQLite database (override: --db <path> or RAGMAC_DB env)
  vec0.dylib        # sqlite-vec extension, downloaded on first run (~1MB)
  models/           # Cached CoreML models
    <repo-id>/      # One directory per HuggingFace repo
```

## Global Flags

```
--db <path>    Database path (also RAGMAC_DB env var)
--quiet        Suppress progress output
--verbose      Extra detail
--format json  Machine-readable output (corpus list, index list, search)
```

## Notes

- `NLEmbedding` word-averages inputs; semantically different sentences may score similarly. Switch to a CoreML model for better retrieval quality.
- First run downloads sqlite-vec (~1MB). Subsequent runs use the cached copy.
- Cross-corpus search (`--corpus all`) merges results only when all corpora share the same embedding model. Otherwise results are grouped by corpus.
