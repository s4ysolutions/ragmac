import Foundation

/// Converts plain-text files to String.
public struct TextConverter {
    public init() {}

    public func convert(url: URL) throws -> String {
        // Detect encoding; fall back to UTF-8 then Latin-1
        if let str = try? String(contentsOf: url, encoding: .utf8) {
            return str
        }
        if let str = try? String(contentsOf: url, encoding: .isoLatin1) {
            return str
        }
        var enc: String.Encoding = .utf8
        return try String(contentsOf: url, usedEncoding: &enc)
    }
}
