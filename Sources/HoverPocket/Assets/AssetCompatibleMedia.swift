import Foundation

actor AssetCompatibleMedia {
    static let shared = AssetCompatibleMedia()
    private var previous: Task<URL, Error>?
    private var generation = 0
    static var executable: URL? {
        let paths = [Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ffmpeg").path, "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
    func convert(_ source: URL, hash: String, mode: String, root: URL) async throws -> URL {
        generation += 1; let current = generation
        defer { if current == generation { previous = nil } }
        let prior = previous
        let task = Task.detached(priority: .utility) {
            _ = try? await prior?.value
            guard let executable = Self.executable else { throw LibraryError.message("互換プレビューを作るメディア処理が利用できません。原本は保存されています。") }
            guard (try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 2 * 1024 * 1024 * 1024 else { throw LibraryError.message("互換プレビューの容量上限を超えています。") }
            let ext = mode == "video" ? "mp4" : mode == "audio" ? "m4a" : "png"
            let directory = root.appendingPathComponent("cache/compatible")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let output = directory.appendingPathComponent(hash + "-v1-" + mode + "." + ext)
            if FileManager.default.fileExists(atPath: output.path) { return output }
            let temporary = directory.appendingPathComponent(UUID().uuidString + "." + ext)
            defer { try? FileManager.default.removeItem(at: temporary) }
            var arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-threads", "2", "-max_alloc", "268435456", "-protocol_whitelist", "file,pipe", "-format_whitelist", "avi,matroska,webm,mov,mp4,m4a,3gp,3g2,mj2,mpeg,mpegts,asf,ogg,flac,wav,mp3,aac,aiff,caf,ac3,eac3,amr,ape,au,wv,png_pipe,jpeg_pipe,tiff_pipe,webp_pipe,bmp_pipe,ico,heif,avif,image2,gif,apng", "-i", source.path]
            switch mode {
            case "video": arguments += ["-map", "0:v:0", "-map", "0:a:0?", "-vf", "scale=1920:1080:force_original_aspect_ratio=decrease:force_divisible_by=2", "-c:v", "h264_videotoolbox", "-b:v", "6M", "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart"]
            case "audio": arguments += ["-map", "0:a:0", "-vn", "-c:a", "aac", "-b:a", "192k"]
            default: arguments += ["-map", "0:v:0", "-frames:v", "1", "-vf", "scale=2048:2048:force_original_aspect_ratio=decrease"]
            }
            arguments += ["-threads", "2", "-fs", "536870912", "-y", temporary.path]
            let process = Process(); process.executableURL = executable; process.arguments = arguments
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run()
            let limit = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: limit)
            process.waitUntilExit(); limit.cancel()
            let outputSize = (try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard process.terminationStatus == 0, outputSize > 0 else {
                throw LibraryError.message("このコーデックの互換プレビューを生成できません。原本は保存されています。")
            }
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]).filter { $0 != temporary }
                .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            var used = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            for file in files where used + outputSize > 2 * 1024 * 1024 * 1024 {
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                do { try FileManager.default.trashItem(at: file, resultingItemURL: nil); used -= size } catch { }
            }
            guard used + outputSize <= 2 * 1024 * 1024 * 1024 else { throw LibraryError.message("互換プレビューの保存容量の上限に達しました。原本は保存されています。") }
            try FileManager.default.moveItem(at: temporary, to: output); return output
        }
        previous = task
        return try await task.value
    }
}
