@preconcurrency import AVFoundation
import AppKit
import SwiftUI

@MainActor
final class AssetDeviceCapture: NSObject, ObservableObject, NSWindowDelegate, AVCapturePhotoCaptureDelegate, AVCaptureFileOutputRecordingDelegate {
    static let shared = AssetDeviceCapture()
    @Published var kind = "cameraPhoto"
    @Published var cameraID = ""
    @Published var microphoneID = ""
    @Published var includeMicrophone = false
    @Published var folderID: String?
    @Published var folders: [LibraryCategory] = []
    @Published private(set) var active = false
    @Published private(set) var recording = false
    @Published private(set) var working = false
    @Published private(set) var status = "デバイスを選び、プレビューを開始してください。"
    @Published private(set) var startedAt: Date?
    let session = AVCaptureSession()
    private var photo: AVCapturePhotoOutput?
    private var file: AVCaptureFileOutput?
    private var window: NSWindow?
    private var indicator: NSPanel?
    private var pendingFile: URL?
    var cameras: [AVCaptureDevice] { AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified).devices }
    var microphones: [AVCaptureDevice] { AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices }
    func show(kind: String, folder: String?) {
        if !active && !working && !recording {
            self.kind = kind; folderID = folder
            cameraID = cameras.first?.uniqueID ?? ""; microphoneID = microphones.first?.uniqueID ?? ""
        }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 540), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "カメラ撮影・録音"; w.isReleasedWhenClosed = false; w.delegate = self
            w.contentView = NSHostingView(rootView: AssetDeviceCaptureView(model: self)); w.center(); window = w
        }
        Task { if let store = try? await AssetLibraryRuntime.shared.store(), let page = try? await store.query(LibraryQuery()) { folders = page.folders } }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if !recording && !working { Task { await stopPreview() } }
        return !working || recording
    }
    private func permission(_ type: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: type)
        default: return false
        }
    }
    func prepare() async {
        guard !working && !active else { return }; working = true; defer { working = false }
        do {
            if kind != "audio", !(await permission(.video)) { throw LibraryError.message("カメラへのアクセスをシステム設定で許可してください。") }
            if kind == "audio" || (kind == "cameraVideo" && includeMicrophone), !(await permission(.audio)) { throw LibraryError.message("マイクへのアクセスをシステム設定で許可してください。") }
            session.beginConfiguration()
            do {
                for input in session.inputs { session.removeInput(input) }; for output in session.outputs { session.removeOutput(output) }
                photo = nil; file = nil
                func add(_ device: AVCaptureDevice?) throws {
                    guard let device else { throw LibraryError.message("選択したデバイスが接続されていません。") }
                    let input = try AVCaptureDeviceInput(device: device)
                    guard session.canAddInput(input) else { throw LibraryError.message("デバイスを使用できません。他の撮影を終了して再試行してください。") }
                    session.addInput(input)
                }
                if kind != "audio" { try add(cameras.first { $0.uniqueID == cameraID }) }
                if kind == "audio" || (kind == "cameraVideo" && includeMicrophone) { try add(microphones.first { $0.uniqueID == microphoneID }) }
                let output: AVCaptureOutput
                if kind == "cameraPhoto" { let o = AVCapturePhotoOutput(); photo = o; output = o }
                else if kind == "audio" { let o = AVCaptureAudioFileOutput(); o.audioSettings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVEncoderBitRateKey: 128000]; file = o; output = o }
                else { let o = AVCaptureMovieFileOutput(); file = o; output = o }
                guard session.canAddOutput(output) else { throw LibraryError.message("このデバイスでは指定した形式で記録できません。") }
                session.addOutput(output); session.commitConfiguration()
            } catch { session.commitConfiguration(); throw error }
            let captureSession = self.session
            await Task.detached { captureSession.startRunning() }.value
            guard session.isRunning else { throw LibraryError.message("デバイスを開始できませんでした。") }
            active = true; status = kind == "audio" ? "準備できました。「録音開始」で保存を始めます。" : "プレビュー中です。撮影または収録開始を押してください。"
        } catch { status = error.localizedDescription; active = false }
    }
    func stopPreview() async {
        guard !recording else { return }
        let session = self.session
        await Task.detached { session.stopRunning() }.value
        active = false
    }
    func capture() {
        guard active, !working, !recording else { return }
        do {
            let root = AssetLibraryRuntime.libraryRoot.deletingLastPathComponent().appendingPathComponent("CapturePending/" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let ext = kind == "cameraPhoto" ? "jpg" : kind == "audio" ? "m4a" : "mov"
            let title = kind == "cameraPhoto" ? "カメラ写真" : kind == "audio" ? "音声録音" : "カメラ動画"
            let url = root.appendingPathComponent(title + " " + LibraryFormat.now().replacingOccurrences(of: ":", with: "-") + "." + ext)
            pendingFile = url; working = true
            if let photo {
                photo.capturePhoto(with: AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg]), delegate: self)
            } else if let audio = file as? AVCaptureAudioFileOutput {
                audio.startRecording(to: url, outputFileType: .m4a, recordingDelegate: self)
            } else if let file { file.startRecording(to: url, recordingDelegate: self) }
        } catch { working = false; status = error.localizedDescription }
    }
    func stop() {
        guard recording else { return }; working = true; status = "保存しています…"; file?.stopRecording()
    }
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation(), failure = error?.localizedDescription
        Task { @MainActor in
            do {
                guard failure == nil, let data, let url = self.pendingFile else { throw LibraryError.message(failure ?? "写真を取得できません。") }
                try data.write(to: url, options: .atomic); await self.save(url)
            } catch { self.working = false; self.status = error.localizedDescription }
        }
    }
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        Task { @MainActor in
            self.working = false; self.recording = true; self.startedAt = Date(); self.status = "記録中です。停止するとライブラリへ保存します。"; self.showIndicator()
        }
    }
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        let completed = error == nil || (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true
        let failure = error?.localizedDescription
        Task { @MainActor in
            self.recording = false; self.startedAt = nil; self.indicator?.orderOut(nil)
            if completed { await self.save(outputFileURL) }
            else { self.working = false; self.status = (failure ?? "収録を保存できませんでした。") + " 保存待ちフォルダにデータを保持しています。"; self.window?.makeKeyAndOrderFront(nil) }
            if self.window?.isVisible != true { await self.stopPreview() }
        }
    }
    private func save(_ url: URL) async {
        defer { working = false }
        do {
            try AssetPendingCapture(folder: folderID, files: [url.lastPathComponent]).write(to: url.deletingLastPathComponent())
            let store = try await AssetLibraryRuntime.shared.store()
            let result = try await store.importFile(url, folder: folderID)
            guard let id = result.assetId, ["saved", "duplicate"].contains(result.status), let saved = try await store.get(id) else { throw LibraryError.message("保存結果を確認できません。") }
            _ = try await store.path(saved, verifyHash: true)
            AssetLibraryRuntime.shared.notifyChange(); status = "保存しました: " + saved.name
            try? FileManager.default.trashItem(at: url.deletingLastPathComponent(), resultingItemURL: nil)
            pendingFile = nil
        } catch { status = "保存できませんでした。保存待ちフォルダから再登録できます。"; window?.makeKeyAndOrderFront(nil) }
    }
    private func showIndicator() {
        if indicator == nil {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.level = .statusBar; p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: AssetRecordingIndicator(model: self)); indicator = p
        }
        if let frame = (window?.screen ?? NSScreen.main)?.visibleFrame { indicator?.setFrame(NSRect(x: frame.midX-115, y: frame.maxY-52, width: 230, height: 42), display: true) }
        indicator?.orderFrontRegardless()
    }
}

private struct AssetDeviceCaptureView: View {
    @ObservedObject var model: AssetDeviceCapture
    var body: some View {
        VStack(spacing: 12) {
            Form {
                Picker("撮影方法", selection: $model.kind) { Text("写真").tag("cameraPhoto"); Text("動画").tag("cameraVideo"); Text("音声").tag("audio") }
                if model.kind != "audio" { Picker("カメラ", selection: $model.cameraID) { ForEach(model.cameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) } } }
                if model.kind == "cameraVideo" { Toggle("マイクの音も録る", isOn: $model.includeMicrophone) }
                if model.kind == "audio" || (model.kind == "cameraVideo" && model.includeMicrophone) { Picker("マイク", selection: $model.microphoneID) { ForEach(model.microphones, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) } } }
                Picker("保存先", selection: $model.folderID) { Text("未分類").tag(nil as String?); ForEach(model.folders, id: \.id) { Text($0.name).tag(Optional($0.id)) } }
            }.disabled(model.active || model.working)
            if model.active && model.kind != "audio" { CameraPreviewView(session: model.session, onReady: {}).frame(minHeight: 180) }
            else { Image(systemName: model.kind == "audio" ? "mic" : "camera").font(.system(size: 48)).frame(maxHeight: .infinity).foregroundStyle(.secondary) }
            Text(model.status).font(.callout).textSelection(.enabled)
            HStack {
                if !model.active { Button("プレビュー・準備を開始") { Task { await model.prepare() } } }
                else if model.recording { Button("停止して保存", action: model.stop).tint(.red) }
                else { Button(model.kind == "cameraPhoto" ? "撮影して保存" : "録音・収録開始", action: model.capture); Button("デバイスを変更") { Task { await model.stopPreview() } } }
                Button("保存待ちフォルダ") { AssetCaptureController.shared.openPending() }
            }.disabled(model.working)
        }.padding(20).frame(minWidth: 480, minHeight: 420)
    }
}
private struct AssetRecordingIndicator: View {
    @ObservedObject var model: AssetDeviceCapture
    var body: some View {
        HStack { Circle().fill(.red).frame(width: 8, height: 8); if let date = model.startedAt { Text(date, style: .timer).monospacedDigit() }; Button("停止して保存", action: model.stop).disabled(model.working) }
            .padding(10).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
