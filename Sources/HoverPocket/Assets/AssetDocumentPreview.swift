import Foundation

enum AssetPreviewFormats {
    static let formats: [String: [String]] = {
        guard let root = Bundle.main.resourceURL,
              let data = try? Data(contentsOf: root.appendingPathComponent("AssetLibrary/preview-formats.json")),
              let value = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return value
    }()
    static func kind(_ ext: String) -> String {
        if ext == "pdf" { return "pdf" }
        // Transport streams use the video decoder; TypeScript source is still readable from external apps.
        return ["image", "video", "audio", "text", "document"].first { formats[$0]?.contains(ext.lowercased()) == true } ?? "other"
    }
}

enum AssetDocumentPreview {
    static let maximumCharacters = 200_000
    static let maximumBytes = 8 * 1024 * 1024
    static func read(_ url: URL, ext: String) throws -> (text: String, truncated: Bool) {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        if AssetPreviewFormats.kind(ext) == "text" {
            let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
            let data = try file.read(upToCount: maximumBytes) ?? Data()
            let encoding: String.Encoding = data.starts(with: [0xff, 0xfe]) ? .utf16LittleEndian : data.starts(with: [0xfe, 0xff]) ? .utf16BigEndian : .utf8
            guard let text = String(data: data, encoding: encoding) ?? String(data: data, encoding: .shiftJIS), !text.contains("\0") else {
                throw LibraryError.message("この文字コードまたはバイナリ形式を表示できません。原本は保存されています。")
            }
            return (String(text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}")).prefix(maximumCharacters)), size > data.count || text.count > maximumCharacters)
        }
        guard size <= 64 * 1024 * 1024 else { throw LibraryError.message("この文書は表示の容量上限を超えています。原本は保存されています。") }
        if ["doc", "docx", "rtf", "odt"].contains(ext) {
            let data = try command("/usr/bin/textutil", ["-convert", "txt", "-stdout", url.path])
            guard let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibraryError.message("表示できる本文がありません。") }
            return (String(text.prefix(maximumCharacters)), text.count > maximumCharacters)
        }
        if ["xlsx", "pptx", "ods", "odp", "epub"].contains(ext) {
            let list = try command("/usr/bin/unzip", ["-Z1", url.path])
            guard let names = String(data: list, encoding: .utf8) else { throw LibraryError.message("文書を展開できません。") }
            let entries = names.split(separator: "\n").map(String.init).filter { name in
                switch ext {
                case "xlsx": return name.hasPrefix("xl/worksheets/sheet") && name.hasSuffix(".xml")
                case "pptx": return name.hasPrefix("ppt/slides/slide") && name.hasSuffix(".xml")
                case "epub": return name.hasSuffix(".xhtml") || name.hasSuffix(".html")
                default: return name == "content.xml"
                }
            }.sorted()
            var strings: [String] = []
            if ext == "xlsx", names.contains("xl/sharedStrings.xml") {
                let parser = DocumentXML(mode: "strings"); try parser.read(command("/usr/bin/unzip", ["-p", url.path, "xl/sharedStrings.xml"]))
                strings = parser.strings
            }
            var output = "", bytes = 0, truncated = false
            for entry in entries.prefix(200) {
                let data = try command("/usr/bin/unzip", ["-p", url.path, entry]); bytes += data.count
                if bytes > maximumBytes { truncated = true; break }
                let parser = DocumentXML(mode: ext, strings: strings); try parser.read(data)
                if ["xlsx", "pptx"].contains(ext) { output += "── \(entry) ──\n" }
                output += parser.text + "\n"
                if output.count > maximumCharacters { truncated = true; break }
            }
            guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibraryError.message("表示できる本文がありません。保護された文書は外部アプリで開いてください。") }
            return (String(output.prefix(maximumCharacters)), truncated || entries.count > 200)
        }
        throw LibraryError.message("この文書の本文表示には外部アプリが必要です。原本は保存されています。")
    }
    private static func command(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        try process.run()
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timer)
        defer { timer.cancel(); try? pipe.fileHandleForReading.close() }
        var data = Data()
        while let chunk = try pipe.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
            data.append(chunk)
            if data.count > maximumBytes { process.terminate(); throw LibraryError.message("文書の展開サイズが表示の上限を超えています。") }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw LibraryError.message("文書を表示できません。形式・破損・保護を確認してください。原本は保存されています。") }
        return data
    }
}

private final class DocumentXML: NSObject, XMLParserDelegate {
    let mode: String
    var shared: [String]
    var strings: [String] = []
    var text = ""
    private var value = "", cellType = "", inText = false, inValue = false, inString = false
    init(mode: String, strings: [String] = []) { self.mode = mode; shared = strings }
    func read(_ data: Data) throws {
        if String(data: data.prefix(1024), encoding: .utf8)?.contains("<!DOCTYPE") == true { throw LibraryError.message("外部参照を含む文書は表示できません。") }
        let parser = XMLParser(data: data); parser.shouldResolveExternalEntities = false; parser.shouldProcessNamespaces = true; parser.delegate = self
        guard parser.parse() else { throw LibraryError.message("文書の本文を読み取れません。") }
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "si" { value = ""; inString = true }
        if elementName == "c" { value = ""; cellType = attributeDict["t"] ?? "" }
        if elementName == "t" { inText = true }
        if elementName == "v" { inValue = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if mode == "strings" || mode == "xlsx" { if inText || inValue { value += string } }
        else { text += string }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "t" { inText = false }
        if elementName == "v" { inValue = false }
        if elementName == "si", inString { strings.append(value); inString = false }
        if elementName == "c" { text += (cellType == "s" && Int(value).map({ shared.indices.contains($0) }) == true ? shared[Int(value)!] : value) + "\t" }
        if ["p", "h", "row", "li"].contains(elementName) { text += "\n" }
    }
}
