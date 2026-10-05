import AppKit
import UniformTypeIdentifiers

@MainActor
enum AssetIncomingDrop {
    static let types = [NSPasteboard.PasteboardType.fileURL, .png, .tiff, .URL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    static func accepts(_ board: NSPasteboard) -> Bool {
        !AssetLibraryRuntime.shared.internalDrag && board.availableType(from: types) != nil
    }
    static func receive(_ board: NSPasteboard, completion: @escaping @MainActor ([URL], String?) -> Void) -> Bool {
        guard accepts(board) else { return false }
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("HoverPocket-Drop-" + UUID().uuidString)
            if let receivers = board.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver], !receivers.isEmpty {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                var remaining = receivers.reduce(0) { $0 + $1.fileNames.count }, files: [URL] = [], failure: String?
                guard remaining > 0 else { return false }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(120))
                    if remaining > 0 { remaining = -1; completion(files, "ファイルの受け取りがタイムアウトしました。一時ファイルは保持されています。") }
                }
                for receiver in receivers {
                    receiver.receivePromisedFiles(atDestination: root, options: [:], operationQueue: .main) { url, error in
                        Task { @MainActor in
                            guard remaining > 0 else { return }
                            if let error { failure = error.localizedDescription } else { files.append(url.resolvingSymlinksInPath()) }
                            remaining -= 1
                            if remaining == 0 { completion(files, failure) }
                        }
                    }
                }
                return true
            }
            if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
                completion(urls, nil); return true
            }
            if let image = NSImage(pasteboard: board), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let url = root.appendingPathComponent("ブラウザ画像.png")
                try AssetMedia.png(cg).write(to: url, options: .atomic)
                completion([url.resolvingSymlinksInPath()], nil); return true
            }
            guard let text = board.string(forType: .URL), let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
            Task {
                do {
                    let file = try await download(url, into: root)
                    completion([file], nil)
                } catch { completion([], error.localizedDescription) }
            }
            return true
        } catch { completion([], error.localizedDescription); return false }
    }
    nonisolated static func download(_ url: URL, into root: URL) async throws -> URL {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForResource = 120
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let mime = response.mimeType, ["image/", "audio/", "video/"].contains(where: mime.hasPrefix) else {
            throw LibraryError.message("画像・音声・動画の直接URLをドロップしてください。ページや配信動画は取り込めません。")
        }
        let limit = 100 * 1024 * 1024
        guard response.expectedContentLength <= limit else { throw LibraryError.message("URLからの取り込みは100MBまでです。ファイルとして保存してからドロップしてください。") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ext = UTType(mimeType: mime)?.preferredFilenameExtension ?? "bin"
        let raw = URL(fileURLWithPath: response.suggestedFilename ?? "メディア").deletingPathExtension().lastPathComponent
        let safe = raw.filter { !$0.isNewline && $0 != ":" && $0 != "/" && $0 != "\\" }.prefix(120)
        let file = root.appendingPathComponent((safe.isEmpty ? "メディア" : String(safe)) + "." + ext)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        var buffer = Data(), size = 0
        for try await byte in bytes {
            try Task.checkCancellation(); size += 1
            guard size <= limit else { throw LibraryError.message("URLからの取り込みは100MBまでです。一時ファイルは保持されています。") }
            buffer.append(byte)
            if buffer.count >= 65536 { try handle.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true) }
        }
        try handle.write(contentsOf: buffer)
        guard size > 0 else { throw LibraryError.message("空のメディアでした。") }
        let quarantine = "0081;" + String(Int(Date().timeIntervalSince1970), radix: 16) + ";HoverPocket;"
        guard quarantine.withCString({ setxattr(file.path, "com.apple.quarantine", $0, strlen($0), 0, 0) }) == 0 else {
            throw LibraryError.message("ダウンロード元の情報を保持できませんでした。一時ファイルは保持されています。")
        }
        return file.resolvingSymlinksInPath()
    }
}
