import Foundation

/// Side on which a tokenizer's output is padded to a fixed sequence length.
public enum PaddingSide: Sendable { case left, right }

/// Common interface for tokenizers used by CoreMLEmbedder.
public protocol TextTokenizer: Sendable {
    func encode(_ text: String) -> (inputIds: [Int32], attentionMask: [Int32])
    /// Which side to add padding tokens on. Last-token-pooling models (e.g. Qwen3)
    /// require `.left` so the final content token lands at the last sequence position;
    /// CLS/mean-pooling BERT models use `.right`.
    var paddingSide: PaddingSide { get }
}

public extension TextTokenizer {
    /// BERT/WordPiece tokenizers and mean-pooling models pad on the right by default.
    var paddingSide: PaddingSide { .right }
}

/// Minimal BERT WordPiece tokenizer for CoreML embedding models.
/// Expects vocab.txt in the model directory (one token per line).
public final class BERTTokenizer: TextTokenizer, Sendable {
    private let vocab: [String: Int]
    private let unkId: Int
    private let clsId: Int
    private let sepId: Int
    private let padId: Int
    private let maxLength: Int

    public init(vocabURL: URL, maxLength: Int = 512) throws {
        let content = try String(contentsOf: vocabURL, encoding: .utf8)
        var vocab: [String: Int] = [:]
        for (i, line) in content.components(separatedBy: "\n").enumerated() {
            let token = line.trimmingCharacters(in: .whitespaces)
            if !token.isEmpty {
                vocab[token] = i
            }
        }
        self.vocab = vocab
        self.unkId = vocab["[UNK]"] ?? 100
        self.clsId = vocab["[CLS]"] ?? 101
        self.sepId = vocab["[SEP]"] ?? 102
        self.padId = vocab["[PAD]"] ?? 0
        self.maxLength = maxLength
    }

    /// Returns (input_ids, attention_mask) padded to maxLength.
    public func encode(_ text: String) -> (inputIds: [Int32], attentionMask: [Int32]) {
        let tokens = tokenize(text)
        // Reserve space for [CLS] and [SEP]
        let maxTokens = maxLength - 2
        let truncated = tokens.prefix(maxTokens)

        var ids: [Int32] = [Int32(clsId)]
        ids.append(contentsOf: truncated.map { Int32(vocab[$0] ?? unkId) })
        ids.append(Int32(sepId))

        let seqLen = ids.count
        var mask: [Int32] = [Int32](repeating: 1, count: seqLen)

        // Pad to maxLength
        let padCount = maxLength - seqLen
        if padCount > 0 {
            ids.append(contentsOf: [Int32](repeating: Int32(padId), count: padCount))
            mask.append(contentsOf: [Int32](repeating: 0, count: padCount))
        }

        return (ids, mask)
    }

    private func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        for word in basicTokenize(text) {
            tokens.append(contentsOf: wordPiece(word))
        }
        return tokens
    }

    private func basicTokenize(_ text: String) -> [String] {
        let lower = text.lowercased()
        var result: [String] = []
        var current = ""
        for char in lower {
            if char.isWhitespace {
                if !current.isEmpty { result.append(current); current = "" }
            } else if isPunctuation(char) {
                if !current.isEmpty { result.append(current); current = "" }
                result.append(String(char))
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private func wordPiece(_ word: String) -> [String] {
        if vocab[word] != nil { return [word] }
        var tokens: [String] = []
        var remaining = Substring(word)
        var isFirst = true
        while !remaining.isEmpty {
            var found = false
            var endIdx = remaining.endIndex
            while endIdx > remaining.startIndex {
                let sub = String(remaining[remaining.startIndex..<endIdx])
                let candidate = isFirst ? sub : "##\(sub)"
                if vocab[candidate] != nil {
                    tokens.append(candidate)
                    remaining = remaining[endIdx...]
                    isFirst = false
                    found = true
                    break
                }
                endIdx = remaining.index(before: endIdx)
            }
            if !found {
                return ["[UNK]"]
            }
        }
        return tokens.isEmpty ? ["[UNK]"] : tokens
    }

    private func isPunctuation(_ char: Character) -> Bool {
        let scalars = char.unicodeScalars
        guard let first = scalars.first else { return false }
        let v = first.value
        if (v >= 33 && v <= 47) || (v >= 58 && v <= 64) ||
           (v >= 91 && v <= 96) || (v >= 123 && v <= 126) { return true }
        return char.unicodeScalars.first?.properties.generalCategory == .otherPunctuation
    }
}
