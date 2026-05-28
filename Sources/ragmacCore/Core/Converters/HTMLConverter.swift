import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Converts HTML files to plain text using NSAttributedString.
public struct HTMLConverter {
    public init() {}

    public func convert(url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return try convert(data: data)
    }

    func convert(data: Data) throws -> String {
        guard let attributed = NSAttributedString(
            html: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ],
            documentAttributes: nil
        ) else {
            throw RagmacError.modelLoadFailed(reason: "NSAttributedString could not parse HTML")
        }
        return attributed.string
    }
}
