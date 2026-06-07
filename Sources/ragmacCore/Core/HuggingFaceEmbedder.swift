import Foundation

/// Downloads a CoreML-tagged model from HuggingFace Hub and wraps it in CoreMLEmbedder.
public final class HuggingFaceEmbedder: Embedder, @unchecked Sendable {
    public let dimensions: Int
    public let identifier: String
    public let source: ModelSource = .hf

    private let inner: CoreMLEmbedder

    /// Downloads (if needed) and loads the model. Throws if coreml tag is missing.
    public init(repoId: String, cacheDir: URL) async throws {
        self.identifier = repoId

        let modelDir = cacheDir.appendingPathComponent(repoId.replacingOccurrences(of: "/", with: "--"))
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

        // Check HF API and validate coreml tag
        let meta = try await HuggingFaceEmbedder.fetchMetadata(repoId: repoId)
        guard meta.tags.contains("coreml") else {
            throw RagmacError.modelNotCoreML(repoId: repoId)
        }

        // Download missing files
        let needed = HuggingFaceEmbedder.selectFiles(from: meta.siblings)
        for filename in needed {
            let dest = modelDir.appendingPathComponent(filename)
            if !FileManager.default.fileExists(atPath: dest.path) {
                fputs("→ Downloading \(filename)...\n", stderr)
                try await HuggingFaceEmbedder.download(repoId: repoId, filename: filename, to: dest)
            }
        }

        self.inner = try CoreMLEmbedder(modelDir: modelDir, modelSource: .hf, identifier: repoId)
        self.dimensions = inner.dimensions
    }

    public func embed(_ text: String) async throws -> [Float] {
        try await inner.embed(text)
    }

    // MARK: - HF API

    private struct HFMetadata: Decodable {
        let tags: [String]
        let siblings: [Sibling]

        struct Sibling: Decodable {
            let rfilename: String
        }
    }

    private static func fetchMetadata(repoId: String) async throws -> HFMetadata {
        let urlStr = "https://huggingface.co/api/models/\(repoId)"
        guard let url = URL(string: urlStr) else {
            throw RagmacError.downloadFailed(url: urlStr, reason: "Invalid URL")
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw RagmacError.downloadFailed(url: urlStr, reason: "HTTP \(code)")
        }
        return try JSONDecoder().decode(HFMetadata.self, from: data)
    }

    /// Picks the model file(s) and supporting files to download.
    private static func selectFiles(from siblings: [HFMetadata.Sibling]) -> [String] {
        let filenames = siblings.map { $0.rfilename }

        // Extract prefix up to and including the .mlpackage directory component.
        // Handles both "foo.mlpackage/..." and "nested/path/foo.mlpackage/..."
        let pkgPrefixes = Set(filenames.compactMap { (filename: String) -> String? in
            let parts = filename.components(separatedBy: "/")
            guard let idx = parts.firstIndex(where: { $0.hasSuffix(".mlpackage") }) else { return nil }
            return parts[...idx].joined(separator: "/")
        })

        var selected: [String] = []
        // Sort to make selection deterministic; prefer smallest (shortest seq len) package
        if let pkgPrefix = pkgPrefixes.sorted().first {
            selected = filenames.filter { $0.hasPrefix(pkgPrefix + "/") || $0 == pkgPrefix }
        } else if let mdl = filenames.first(where: { $0.hasSuffix(".mlmodel") }) {
            selected = [mdl]
        }

        // Grab top-level BERT support files or tokenizer/ subdirectory
        let bertFiles = ["vocab.txt", "tokenizer_config.json", "special_tokens_map.json"]
        for s in bertFiles where filenames.contains(s) && !selected.contains(s) {
            selected.append(s)
        }
        // BPE / Qwen-style tokenizer lives in tokenizer/ subdir
        let tokenizerFiles = filenames.filter { $0.hasPrefix("tokenizer/") }
        for s in tokenizerFiles where !selected.contains(s) {
            selected.append(s)
        }
        return selected
    }

    private static func download(repoId: String, filename: String, to dest: URL) async throws {
        let urlStr = "https://huggingface.co/\(repoId)/resolve/main/\(filename)"
        guard let url = URL(string: urlStr) else {
            throw RagmacError.downloadFailed(url: urlStr, reason: "Invalid URL")
        }

        let (tmpURL, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw RagmacError.downloadFailed(url: urlStr, reason: "HTTP \(code)")
        }

        let parent = dest.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: tmpURL, to: dest)
    }
}
