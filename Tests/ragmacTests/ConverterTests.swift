import XCTest
@testable import ragmacCore

final class ConverterTests: XCTestCase {

    // MARK: - Markdown

    func testMarkdownStripsHeaders() {
        let md = "# Title\n## Subtitle\nParagraph text."
        let result = MarkdownConverter().stripMarkdown(md)
        XCTAssertFalse(result.contains("#"))
        XCTAssertTrue(result.contains("Title"))
        XCTAssertTrue(result.contains("Paragraph text."))
    }

    func testMarkdownStripsBoldAndItalic() {
        let md = "**bold** and *italic* and _underscore_."
        let result = MarkdownConverter().stripMarkdown(md)
        XCTAssertFalse(result.contains("**"))
        XCTAssertFalse(result.contains("__"))
        XCTAssertTrue(result.contains("bold"))
        XCTAssertTrue(result.contains("italic"))
    }

    func testMarkdownConvertsLinks() {
        let md = "See [the docs](https://example.com) for details."
        let result = MarkdownConverter().stripMarkdown(md)
        XCTAssertFalse(result.contains("https://example.com"))
        XCTAssertTrue(result.contains("the docs"))
    }

    func testMarkdownPreservesCodeContent() {
        let md = "```swift\nlet x = 42\n```"
        let result = MarkdownConverter().stripMarkdown(md)
        XCTAssertTrue(result.contains("let x = 42"), "Code block contents should be preserved")
    }

    // MARK: - HTML (via HTMLConverter inline test)

    func testHTMLConvert() throws {
        let html = "<html><body><h1>Title</h1><p>Hello world.</p></body></html>"
        let data = html.data(using: .utf8)!
        let result = try HTMLConverter().convert(data: data)
        XCTAssertTrue(result.contains("Title"))
        XCTAssertTrue(result.contains("Hello world."))
        XCTAssertFalse(result.contains("<h1>"))
    }

    // MARK: - Unsupported extension

    func testUnsupportedExtensionThrows() throws {
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.xyz")
        try "data".write(to: tmpURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        do {
            _ = try Converter.convert(url: tmpURL)
            XCTFail("Expected unsupportedFileType error")
        } catch RagmacError.unsupportedFileType {
            // expected
        }
    }

    // MARK: - Text

    func testTextConverterReadsUTF8() throws {
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_\(UUID().uuidString).txt")
        let content = "Hello, swift! 🦉"
        try content.write(to: tmpURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let result = try TextConverter().convert(url: tmpURL)
        XCTAssertEqual(result, content)
    }
}
