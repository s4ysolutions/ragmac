import Foundation

/// Parses --model spec strings and constructs the appropriate Embedder.
public enum ModelResolver {
    /// Parses a model spec and returns a ready-to-use Embedder.
    /// Spec forms: "native", "hf:<repo-id>", "local:<path>"
    public static func resolve(_ spec: String, ragmacDir: URL) async throws -> any Embedder {
        if spec == "native" {
            return try NativeEmbedder()
        }

        if spec.hasPrefix("hf:") {
            let repoId = String(spec.dropFirst(3))
            if repoId.isEmpty { throw RagmacError.invalidModelSpec(spec) }
            let cacheDir = ragmacDir.appendingPathComponent("models")
            return try await HuggingFaceEmbedder(repoId: repoId, cacheDir: cacheDir)
        }

        if spec.hasPrefix("local:") {
            var path = String(spec.dropFirst(6))
            if path.hasPrefix("~") {
                path = FileManager.default.homeDirectoryForCurrentUser.path + path.dropFirst()
            }
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw RagmacError.modelLoadFailed(reason: "Path does not exist: \(path)")
            }
            return try CoreMLEmbedder(modelDir: url.deletingLastPathComponent(), modelSource: .local, identifier: path)
        }

        throw RagmacError.invalidModelSpec(spec)
    }
}
