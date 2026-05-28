import Foundation

/// All errors produced by ragmac with actionable user-facing messages.
public enum RagmacError: LocalizedError {
    case corpusNotFound(String)
    case corpusAlreadyExists(String)
    case modelNotCoreML(repoId: String)
    case modelLoadFailed(reason: String)
    case unsupportedFileType(String)
    case dimensionMismatch(expected: Int, got: Int)
    case databaseError(underlying: Error)
    case mcpProtocolError(message: String)
    case downloadFailed(url: String, reason: String)
    case networkError(underlying: Error)
    case systemError(String)
    case invalidModelSpec(String)

    public var errorDescription: String? {
        switch self {
        case .corpusNotFound(let name):
            return "Corpus '\(name)' not found. Run `ragmac corpus list` to see available corpora."
        case .corpusAlreadyExists(let name):
            return "Corpus '\(name)' already exists. Use a different name or delete it first with `ragmac corpus delete`."
        case .modelNotCoreML(let repoId):
            return "Model '\(repoId)' does not have a 'coreml' tag on HuggingFace. Only CoreML-exported models are supported."
        case .modelLoadFailed(let reason):
            return "Failed to load model: \(reason)"
        case .unsupportedFileType(let ext):
            return "File type '\(ext)' is not supported. Supported: txt, md, html, htm, pdf, epub, docx."
        case .dimensionMismatch(let expected, let got):
            return "Embedding dimension mismatch: expected \(expected), got \(got). The model may not match the corpus."
        case .databaseError(let underlying):
            return "Database error: \(underlying.localizedDescription)"
        case .mcpProtocolError(let message):
            return "MCP protocol error: \(message)"
        case .downloadFailed(let url, let reason):
            return "Download failed for '\(url)': \(reason)"
        case .networkError(let underlying):
            return "Network error: \(underlying.localizedDescription)"
        case .systemError(let message):
            return message
        case .invalidModelSpec(let spec):
            return "Invalid model spec '\(spec)'. Use 'native', 'hf:<repo-id>', or 'local:<path>'."
        }
    }
}
