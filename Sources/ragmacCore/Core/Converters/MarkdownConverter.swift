import Foundation

/// Converts Markdown files to plain text (strips syntax, keeps code block contents).
public struct MarkdownConverter {
    public init() {}

    public func convert(url: URL) throws -> String {
        let raw = try TextConverter().convert(url: url)
        return stripMarkdown(raw)
    }

    func stripMarkdown(_ text: String) -> String {
        var result = text

        // Remove fenced code block markers but keep contents
        result = result.replacingOccurrences(of: #"```[^\n]*\n"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "```", with: "")

        // Remove ATX headers (# ## etc.) — keep the text
        result = result.replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: [.regularExpression, .anchored])
        result = result.replacingOccurrences(of: #"\n#{1,6}\s+"#, with: "\n", options: .regularExpression)

        // Remove bold/italic markers
        result = result.replacingOccurrences(of: #"\*{1,3}([^\*]+)\*{1,3}"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"_{1,3}([^_]+)_{1,3}"#, with: "$1", options: .regularExpression)

        // Remove inline code backticks
        result = result.replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)

        // Convert links: [text](url) -> text
        result = result.replacingOccurrences(of: #"\[([^\]]+)\]\([^\)]+\)"#, with: "$1", options: .regularExpression)

        // Remove images: ![alt](url)
        result = result.replacingOccurrences(of: #"!\[[^\]]*\]\([^\)]+\)"#, with: "", options: .regularExpression)

        // Remove horizontal rules
        result = result.replacingOccurrences(of: #"^[-*_]{3,}\s*$"#, with: "", options: [.regularExpression, .anchored])
        result = result.replacingOccurrences(of: #"\n[-*_]{3,}\s*\n"#, with: "\n\n", options: .regularExpression)

        // Remove blockquote markers
        result = result.replacingOccurrences(of: #"^>\s?"#, with: "", options: [.regularExpression, .anchored])
        result = result.replacingOccurrences(of: #"\n>\s?"#, with: "\n", options: .regularExpression)

        // Remove list markers
        result = result.replacingOccurrences(of: #"^[-*+]\s+"#, with: "", options: [.regularExpression, .anchored])
        result = result.replacingOccurrences(of: #"\n[-*+]\s+"#, with: "\n", options: .regularExpression)
        result = result.replacingOccurrences(of: #"^\d+\.\s+"#, with: "", options: [.regularExpression, .anchored])
        result = result.replacingOccurrences(of: #"\n\d+\.\s+"#, with: "\n", options: .regularExpression)

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
