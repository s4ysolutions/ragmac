import Foundation

/// GPT-2 / Qwen style byte-level BPE tokenizer.
/// Reads `tokenizer.json` (HuggingFace fast tokenizer format).
public final class BPETokenizer: TextTokenizer, @unchecked Sendable {
    private let vocab: [String: Int32]
    private let merges: [String: Int]
    private let byteToUnicode: [UInt8: String]
    public let maxLength: Int

    public init(tokenizerDir: URL, maxLength: Int = 512) throws {
        self.maxLength = maxLength

        let url = tokenizerDir.appendingPathComponent("tokenizer.json")
        let data = try Data(contentsOf: url)
        let json = try JSONDecoder().decode(TokenizerJSONFile.self, from: data)

        guard json.model.type.lowercased() == "bpe" else {
            throw RagmacError.modelLoadFailed(reason: "Expected BPE tokenizer, got \(json.model.type)")
        }

        self.vocab = Dictionary(uniqueKeysWithValues: json.model.vocab.map { ($0.key, Int32($0.value)) })

        var mergeMap: [String: Int] = [:]
        mergeMap.reserveCapacity(json.model.merges.count)
        for (i, merge) in json.model.merges.enumerated() {
            mergeMap[merge] = i
        }
        self.merges = mergeMap
        self.byteToUnicode = BPETokenizer.buildByteToUnicode()
    }

    public func encode(_ text: String) -> (inputIds: [Int32], attentionMask: [Int32]) {
        var ids: [Int32] = []
        for segment in splitWithPattern(text) {
            let unicodeStr = segment.utf8.map { byteToUnicode[$0] ?? "\u{FFFD}" }.joined()
            for token in applyBPE(unicodeStr) {
                if let id = vocab[token] {
                    ids.append(id)
                }
            }
            if ids.count >= maxLength { break }
        }
        let truncated = Array(ids.prefix(maxLength))
        return (truncated, [Int32](repeating: 1, count: truncated.count))
    }

    // MARK: - BPE

    private func applyBPE(_ token: String) -> [String] {
        guard token.count > 1 else { return token.isEmpty ? [] : [token] }
        var word = token.map { String($0) }
        while word.count > 1 {
            var bestPriority = Int.max
            var bestIdx = -1
            for i in 0..<(word.count - 1) {
                let pair = word[i] + " " + word[i + 1]
                if let p = merges[pair], p < bestPriority {
                    bestPriority = p
                    bestIdx = i
                }
            }
            guard bestIdx >= 0 else { break }
            word[bestIdx] = word[bestIdx] + word[bestIdx + 1]
            word.remove(at: bestIdx + 1)
        }
        return word
    }

    // MARK: - Byte-to-unicode (GPT-2 mapping)

    private static func buildByteToUnicode() -> [UInt8: String] {
        // Printable bytes that map to themselves
        var pairs: [(UInt8, Int)] = []
        let selfMapped: [ClosedRange<UInt8>] = [33...126, 161...172, 174...255]
        for range in selfMapped {
            for b in range { pairs.append((b, Int(b))) }
        }
        let selfMappedSet = Set(pairs.map { $0.0 })
        var next = 256
        for b in (0...255).map({ UInt8($0) }) where !selfMappedSet.contains(b) {
            pairs.append((b, next))
            next += 1
        }
        var result: [UInt8: String] = [:]
        for (b, c) in pairs {
            result[b] = String(Unicode.Scalar(c)!)
        }
        return result
    }

    // MARK: - Pre-tokenizer regex (GPT-2 / Qwen pattern)

    private static let pattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}{1,3}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+"#
        )
    }()

    private func splitWithPattern(_ text: String) -> [String] {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return BPETokenizer.pattern.matches(in: text, range: range).map { ns.substring(with: $0.range) }
    }
}

// MARK: - tokenizer.json decode types

private struct TokenizerJSONFile: Decodable {
    let model: Model

    struct Model: Decodable {
        let type: String
        let vocab: [String: Int]
        let merges: [String]  // normalized to "a b" form regardless of source format

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.decode(String.self, forKey: .type)
            vocab = try c.decode([String: Int].self, forKey: .vocab)

            // merges can be ["a b", ...] or [["a","b"], ...]
            if let strings = try? c.decode([String].self, forKey: .merges) {
                merges = strings
            } else {
                let pairs = try c.decode([[String]].self, forKey: .merges)
                merges = pairs.compactMap { $0.count == 2 ? "\($0[0]) \($0[1])" : nil }
            }
        }

        enum CodingKeys: String, CodingKey { case type, vocab, merges }
    }
}
