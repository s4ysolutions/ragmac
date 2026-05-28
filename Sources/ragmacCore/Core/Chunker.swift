import Foundation

/// Splits plain text into overlapping chunks suitable for embedding.
/// Target: 2048 chars per chunk (~512 tokens), 10% overlap (~205 chars).
public enum Chunker {
    static let targetSize = 2048
    static let overlap = 205

    /// Splits text into chunks with character offsets.
    public static func chunk(_ text: String) -> [ChunkContent] {
        guard !text.isEmpty else { return [] }

        var chunks: [ChunkContent] = []
        var startOffset = 0
        var position = 0
        let totalLength = text.utf16.count

        while startOffset < totalLength {
            let endOffset = min(startOffset + targetSize, totalLength)
            var splitAt = endOffset

            if splitAt < totalLength {
                // Prefer paragraph break
                splitAt = findSplit(in: text, from: startOffset, near: endOffset, totalLength: totalLength)
            }

            let startIdx = text.utf16Index(at: startOffset)
            let endIdx = text.utf16Index(at: splitAt)
            let chunkText = String(text[startIdx..<endIdx]).trimmingCharacters(in: .whitespacesAndNewlines)

            if !chunkText.isEmpty {
                chunks.append(ChunkContent(
                    text: chunkText,
                    position: position,
                    startOffset: startOffset,
                    endOffset: splitAt
                ))
                position += 1
            }

            // Once we've covered to the end of the text, we're done.
            if splitAt >= totalLength { break }

            // Next chunk starts with overlap.
            startOffset = splitAt - overlap
        }

        return chunks
    }

    private static func findSplit(in text: String, from start: Int, near target: Int, totalLength: Int) -> Int {
        // Search window: allow looking back up to 20% of chunk size
        let searchStart = max(start + 1, target - targetSize / 5)

        // Try paragraph break (\n\n)
        if let pos = lastOccurrence(of: "\n\n", in: text, from: searchStart, to: target) {
            return pos + 2
        }

        // Try single newline
        if let pos = lastOccurrence(of: "\n", in: text, from: searchStart, to: target) {
            return pos + 1
        }

        // Try sentence boundary (. followed by space)
        if let pos = lastSentenceBoundary(in: text, from: searchStart, to: target) {
            return pos
        }

        // Hard cut at target
        return target
    }

    private static func lastOccurrence(of substring: String, in text: String, from: Int, to: Int) -> Int? {
        let startIdx = text.utf16Index(at: from)
        let endIdx = text.utf16Index(at: to)
        let range = startIdx..<endIdx
        guard let found = text.range(of: substring, options: .backwards, range: range) else { return nil }
        return text.utf16.distance(from: text.startIndex, to: found.lowerBound)
    }

    private static func lastSentenceBoundary(in text: String, from: Int, to: Int) -> Int? {
        let startIdx = text.utf16Index(at: from)
        let endIdx = text.utf16Index(at: to)
        let sub = text[startIdx..<endIdx]
        var lastBoundary: Int? = nil
        var i = sub.startIndex
        while i < sub.endIndex {
            let c = sub[i]
            let next = sub.index(after: i)
            if (c == "." || c == "!" || c == "?") && next < sub.endIndex && sub[next] == " " {
                let offset = from + text.utf16.distance(from: startIdx, to: next)
                lastBoundary = offset
            }
            i = next
        }
        return lastBoundary
    }
}

private extension String {
    func utf16Index(at offset: Int) -> String.Index {
        let clamped = min(offset, utf16.count)
        return utf16.index(utf16.startIndex, offsetBy: clamped)
    }
}
