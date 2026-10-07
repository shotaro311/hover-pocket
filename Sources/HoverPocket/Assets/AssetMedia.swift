import AppKit
import AVFoundation
import PDFKit
import ImageIO
import WebKit
import UniformTypeIdentifiers
import QuickLookThumbnailing

struct LibraryFrame: Codable, Sendable {
    let id: String
    let kind: String
    var width: Int = 0
    var height: Int = 0
    var pages: Int = 0
    var dataUrl: String? = nil
    var videoUrl: String? = nil
    var audioUrl: String? = nil
    var error: String? = nil
    var textContent: String? = nil
    var truncated = false
}

enum AssetMedia {
    static var audioExtensions: Set<String> { Set(AssetPreviewFormats.formats["audio"] ?? []) }
    static func image(_ url: URL, maximum: Int = 4096) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, Double(width) * Double(height) <= 200_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: maximum
              ] as CFDictionary) else { throw LibraryError.message("画像を表示できません。破損または画素数の上限を確認してください。原本は保存されています。") }
        return image
    }
    static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw LibraryError.message("画像を書き出せません。") }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw LibraryError.message("画像の保存に失敗しました。") }
        return data as Data
    }
    private static func quickLook(_ url: URL, maximum: Int) async throws -> CGImage {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: maximum, height: maximum), scale: 1, representationTypes: .thumbnail)
        return try await withCheckedThrowingContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { result, error in
                if let image = result?.cgImage { continuation.resume(returning: image) }
                else { continuation.resume(throwing: error ?? LibraryError.message("この形式を表示できません。原本は保存されています。")) }
            }
        }
    }
    static func frame(_ a: LibraryAsset, url: URL, page: Int = 1, thumbnail: Bool = false, root: URL? = nil) async -> LibraryFrame {
        var result = LibraryFrame(id: a.id, kind: AssetPreviewFormats.kind(a.extension))
        do {
            var image: CGImage?
            switch result.kind {
            case "image":
                do { image = try Self.image(url, maximum: thumbnail ? 360 : 4096) }
                catch { image = try await quickLook(url, maximum: thumbnail ? 360 : 2200) }
            case "pdf":
                guard let document = PDFDocument(url: url) else { throw LibraryError.message("PDFが破損しているか未対応です。") }
                guard !document.isEncrypted else { throw LibraryError.message("暗号化PDFはアプリ内で表示できません。") }
                result.pages = document.pageCount
                guard let p = document.page(at: max(0, min(document.pageCount - 1, page - 1))) else { throw LibraryError.message("PDFにページがありません。") }
                let rect = p.bounds(for: .mediaBox), maximum: CGFloat = thumbnail ? 360 : 2200
                let scale = min(3, maximum / max(rect.width, rect.height))
                let size = CGSize(width: max(1, rect.width * scale), height: max(1, rect.height * scale))
                image = p.thumbnail(of: size, for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil)
            case "video":
                let asset = AVURLAsset(url: url)
                guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw LibraryError.message("この動画は再生できません。原本は保存されています。") }
                let size = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
                let displayed = size.applying(transform)
                result.width = Int(abs(displayed.width)); result.height = Int(abs(displayed.height))
                let generator = AVAssetImageGenerator(asset: asset); generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: thumbnail ? 360 : 1280, height: thumbnail ? 360 : 1280)
                image = try await generator.image(at: .zero).image
            case "text", "document":
                do {
                    let content = try await Task.detached { try AssetDocumentPreview.read(url, ext: a.extension) }.value
                    result.textContent = thumbnail ? String(content.text.prefix(700)) : content.text
                    result.truncated = content.truncated; result.width = 860; result.height = 600
                } catch {
                    if result.kind == "document" { image = try await quickLook(url, maximum: thumbnail ? 360 : 2200) }
                    else { throw error }
                }
            default: break
            }
            if let image {
                if result.kind != "video" { result.width = image.width; result.height = image.height }
                result.dataUrl = "data:image/png;base64," + (try png(image)).base64EncodedString()
            }
        } catch {
            if ["image", "video"].contains(result.kind), let root, AssetCompatibleMedia.executable != nil,
               let converted = try? await AssetCompatibleMedia.shared.convert(url, hash: a.sha256, mode: "image", root: root),
               let image = try? Self.image(converted, maximum: thumbnail ? 360 : 2200), let bytes = try? png(image) {
                result.dataUrl = "data:image/png;base64," + bytes.base64EncodedString()
                result.width = image.width; result.height = image.height
            } else { result.error = error.localizedDescription }
        }
        return result
    }
}

// Only unguessable, in-memory leases can read a managed original. No file-system paths enter the page.
@MainActor
final class AssetMediaScheme: NSObject, WKURLSchemeHandler {
    var leases: [String: URL] = [:]
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    func lease(_ url: URL) -> String {
        let id = UUID().uuidString.lowercased(); leases[id] = url
        return "hpasset://media/" + id
    }
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let file = leases[url.lastPathComponent] else {
            task.didFailWithError(LibraryError.message("プレビューが終了しています。")); return
        }
        let key = ObjectIdentifier(task)
        tasks[key] = Task { @MainActor in
            do {
                let fileSize = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as! NSNumber).int64Value
                let range = task.request.value(forHTTPHeaderField: "Range")
                var start: Int64 = 0, end = max(0, fileSize - 1)
                if let range, range.hasPrefix("bytes=") {
                    let parts = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
                    if parts.count == 2 {
                        start = Int64(parts[0]) ?? 0
                        end = min(end, Int64(parts[1]) ?? end)
                    }
                }
                guard start >= 0, end >= start, start < fileSize else { throw LibraryError.message("動画の読み取り範囲が不正です。") }
                var headers = ["Content-Type": UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "video/mp4",
                    "Accept-Ranges": "bytes", "Content-Length": String(end - start + 1)]
                if range != nil { headers["Content-Range"] = "bytes \(start)-\(end)/\(fileSize)" }
                task.didReceive(HTTPURLResponse(url: url, statusCode: range == nil ? 200 : 206, httpVersion: "HTTP/1.1", headerFields: headers)!)
                let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
                try input.seek(toOffset: UInt64(start)); var remaining = end - start + 1
                while remaining > 0 {
                    try Task.checkCancellation()
                    guard let chunk = try input.read(upToCount: Int(min(remaining, 65_536))), !chunk.isEmpty else { break }
                    task.didReceive(chunk); remaining -= Int64(chunk.count)
                    await Task.yield()
                }
                if !Task.isCancelled { task.didFinish() }
            } catch { if !Task.isCancelled { task.didFailWithError(error) } }
            tasks[key] = nil
        }
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        let key = ObjectIdentifier(task); tasks.removeValue(forKey: key)?.cancel()
    }
    func revoke() { for task in tasks.values { task.cancel() }; tasks.removeAll(); leases.removeAll() }
}
