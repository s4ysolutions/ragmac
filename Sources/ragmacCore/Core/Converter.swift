import Foundation

/// Dispatches file-to-text conversion based on extension.
public enum Converter {
    public struct Result {
        public let text: String
        public let skipped: [URL]
        public let warnings: [String]
    }

    /// Converts a single file to plain text. Throws `RagmacError.unsupportedFileType` for unknown extensions.
    public static func convert(url: URL) throws -> String {
        switch url.pathExtension.lowercased() {
        case "txt":
            return try TextConverter().convert(url: url)
        case "md", "markdown":
            return try MarkdownConverter().convert(url: url)
        case "html", "htm":
            return try HTMLConverter().convert(url: url)
        case "pdf":
            return try PDFConverter().convert(url: url)
        case "epub":
            return try EPUBConverter().convert(url: url)
        case "docx":
            return try DOCXConverter().convert(url: url)
        default:
            throw RagmacError.unsupportedFileType(".\(url.pathExtension)")
        }
    }

    /// Converts all files under a path (recursively if directory), skipping unsupported types.
    public static func convertAll(path: String) throws -> Result {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            throw RagmacError.systemError("Path not found: \(path)")
        }

        let urls: [URL]
        if isDir.boolValue {
            let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])
            urls = (enumerator?.compactMap { $0 as? URL }
                .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }) ?? []
        } else {
            urls = [url]
        }

        var texts: [String] = []
        var skipped: [URL] = []
        var warnings: [String] = []

        for fileURL in urls.sorted(by: { $0.path < $1.path }) {
            do {
                let text = try convert(url: fileURL)
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    texts.append(text)
                }
            } catch RagmacError.unsupportedFileType {
                skipped.append(fileURL)
            } catch {
                warnings.append("⚠ \(fileURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        return Result(text: texts.joined(separator: "\n\n"), skipped: skipped, warnings: warnings)
    }
}
