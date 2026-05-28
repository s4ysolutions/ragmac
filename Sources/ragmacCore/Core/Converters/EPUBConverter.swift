import Foundation

/// Converts EPUB files to plain text by parsing OPF spine and XHTML content.
public struct EPUBConverter {
    public init() {}

    public func convert(url: URL) throws -> String {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: tmpDir) }

        // Unzip EPUB
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-q", url.path, "-d", tmpDir.path]
        try proc.run()
        proc.waitUntilExit()

        if proc.terminationStatus != 0 {
            throw RagmacError.systemError("Failed to unzip EPUB: \(url.lastPathComponent)")
        }

        // Find container.xml to locate OPF
        let containerURL = tmpDir.appendingPathComponent("META-INF/container.xml")
        guard fm.fileExists(atPath: containerURL.path) else {
            throw RagmacError.systemError("Invalid EPUB: missing META-INF/container.xml")
        }

        let opfPath = try parseContainerXML(at: containerURL)
        let opfURL = tmpDir.appendingPathComponent(opfPath)
        let spineFiles = try parseOPF(at: opfURL)

        var parts: [String] = []
        let opfDir = opfURL.deletingLastPathComponent()
        for href in spineFiles {
            let fileURL = opfDir.appendingPathComponent(href)
            if let text = try? extractXHTMLText(at: fileURL), !text.isEmpty {
                parts.append(text)
            }
        }

        return parts.joined(separator: "\n\n")
    }

    private func parseContainerXML(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let parser = SimpleXMLParser(data: data)
        parser.parse()
        return parser.attributes["rootfile"]?["full-path"] ?? "OEBPS/content.opf"
    }

    private func parseOPF(at url: URL) throws -> [String] {
        let data = try Data(contentsOf: url)
        let parser = SimpleXMLParser(data: data)
        parser.parse()
        return parser.spineHrefs
    }

    private func extractXHTMLText(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return try HTMLConverter().convert(data: data)
    }
}

/// Minimal SAX-style XML parser for EPUB container and OPF files.
private final class SimpleXMLParser: NSObject, XMLParserDelegate {
    var attributes: [String: [String: String]] = [:]
    var spineHrefs: [String] = []
    private var manifestItems: [String: String] = [:]  // id -> href
    private var spineIds: [String] = []
    private var inSpine = false
    private let data: Data

    init(data: Data) {
        self.data = data
    }

    func parse() {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes attributeDict: [String: String] = [:]) {
        switch elementName.lowercased() {
        case "rootfile":
            self.attributes["rootfile"] = attributeDict
        case "item":
            if let id = attributeDict["id"], let href = attributeDict["href"] {
                manifestItems[id] = href
            }
        case "itemref":
            if let idref = attributeDict["idref"] {
                spineIds.append(idref)
            }
            inSpine = true
        case "spine":
            inSpine = true
        default:
            break
        }
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        spineHrefs = spineIds.compactMap { manifestItems[$0] }
    }
}
