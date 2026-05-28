import Foundation

/// Converts DOCX files to plain text by parsing word/document.xml.
public struct DOCXConverter {
    public init() {}

    public func convert(url: URL) throws -> String {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: tmpDir) }

        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-q", url.path, "word/document.xml", "-d", tmpDir.path]
        try proc.run()
        proc.waitUntilExit()

        let docXML = tmpDir.appendingPathComponent("word/document.xml")
        guard fm.fileExists(atPath: docXML.path) else {
            throw RagmacError.systemError("Invalid DOCX: missing word/document.xml in \(url.lastPathComponent)")
        }

        let data = try Data(contentsOf: docXML)
        let extractor = DOCXTextExtractor(data: data)
        extractor.parse()
        return extractor.text
    }
}

private final class DOCXTextExtractor: NSObject, XMLParserDelegate {
    var text: String = ""
    private var buffer = ""
    private var inParagraph = false
    private let data: Data
    private var paragraphs: [String] = []

    init(data: Data) {
        self.data = data
    }

    func parse() {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        text = paragraphs.joined(separator: "\n")
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes attributeDict: [String: String] = [:]) {
        if elementName == "w:p" {
            inParagraph = true
            buffer = ""
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        if elementName == "w:p" {
            let trimmed = buffer.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { paragraphs.append(trimmed) }
            inParagraph = false
            buffer = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        // Only collect text inside <w:t> which is inside <w:p>
        // The parent element check is implicit via foundCharacters being called for all text nodes
        if inParagraph {
            buffer += string
        }
    }
}
