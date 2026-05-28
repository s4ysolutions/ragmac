import Foundation
import PDFKit

/// Converts PDF files to plain text using PDFKit.
public struct PDFConverter {
    public init() {}

    public func convert(url: URL) throws -> String {
        guard let doc = PDFDocument(url: url) else {
            throw RagmacError.systemError("PDFKit could not open \(url.lastPathComponent)")
        }
        var parts: [String] = []
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i), let text = page.string {
                parts.append(text)
            }
        }
        return parts.joined(separator: "\n\n")
    }
}
