import AppKit
import AVFoundation
import ScreenCaptureKit
import SwiftUI
import Carbon

struct AssetCapturePreferences: Codable {
    var systemAudio = true
    var microphone = true
    var screenshotToastSeconds = 5
    var screenshotKey: UInt32 = UInt32(kVK_ANSI_S)
    var recordingKey: UInt32 = UInt32(kVK_ANSI_R)
    var modifiers: UInt32 = UInt32(cmdKey | optionKey)
    var screenshotModifiers: UInt32?
    var recordingModifiers: UInt32?
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        systemAudio = try c.decodeIfPresent(Bool.self, forKey: .systemAudio) ?? true
        microphone = try c.decodeIfPresent(Bool.self, forKey: .microphone) ?? true
        screenshotToastSeconds = try c.decodeIfPresent(Int.self, forKey: .screenshotToastSeconds) ?? 5
        screenshotKey = try c.decodeIfPresent(UInt32.self, forKey: .screenshotKey) ?? UInt32(kVK_ANSI_S)
        recordingKey = try c.decodeIfPresent(UInt32.self, forKey: .recordingKey) ?? UInt32(kVK_ANSI_R)
        modifiers = try c.decodeIfPresent(UInt32.self, forKey: .modifiers) ?? UInt32(cmdKey | optionKey)
        screenshotModifiers = try c.decodeIfPresent(UInt32.self, forKey: .screenshotModifiers)
        recordingModifiers = try c.decodeIfPresent(UInt32.self, forKey: .recordingModifiers)
    }
    var recordingShortcut: String { AppShortcutBindings.format(code: recordingKey, modifiers: recordingModifiers ?? modifiers) }
}

@MainActor
final class AssetCaptureController: NSObject, ObservableObject {
    static let shared = AssetCaptureController()
    @Published var recording = false
    @Published var busy = false
    @Published var status = ""
    var preferences = AssetCapturePreferences()
    private var overlays: [NSPanel] = []
    private var recorder: AssetScreenRecorder?
    private(set) var recordingID: String?
    private(set) var lastRecordingAsset: LibraryAsset?
    private(set) var lastRecordingError: String?
    private var recordingName: String?
    private let libraryStore: () async throws -> AssetLibraryStore
    private let pendingRoot: URL?

    init(store: @escaping () async throws -> AssetLibraryStore = { try await AssetLibraryRuntime.shared.store() }, pendingRoot: URL? = nil) {
        self.libraryStore = store; self.pendingRoot = pendingRoot
        super.init()
    }
    private var toast: AssetScreenshotToast?
    private var hotkeys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var registeredBindings: [String: AppShortcutBindings.Key] = [:]
    private weak var shortcutSettings: AppSettings?
    private var shortcutAction: ((String) -> Void)?
    private var shortcutsSuspended = false
    private var recordingFolder: String?
    private var settingsWindow: NSWindow?
    private var recordDirectory: URL?
    private var preferencesURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HoverPocket/capture-settings.json")
    }
    func start() {
        if let data = try? Data(contentsOf: preferencesURL), let value = try? JSONDecoder().decode(AssetCapturePreferences.self, from: data) { preferences = value }
        preferences.screenshotToastSeconds = min(30, max(0, preferences.screenshotToastSeconds))
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &id)
            let number = Int(id.id)
            Task { @MainActor in
                guard number > 0, number <= AppShortcutBindings.actions.count else { return }
                let action = AppShortcutBindings.actions[number - 1], capture = AssetCaptureController.shared
                switch action {
                case "screenshot": await capture.screenshot(folder: nil)
                case "recording": await capture.toggleRecording(folder: nil)
                case "regionRecording": await capture.toggleRegionRecording(folder: nil)
                default: capture.shortcutAction?(action)
                }
            }
            return noErr
        }, 1, &spec, nil, &handler)
        registerHotkeys()
    }
    private func registerHotkeys() {
        do { try installBindings(shortcutBindings(settings: shortcutSettings)) }
        catch { status = error.localizedDescription }
    }
    func configureShortcuts(settings: AppSettings, action: @escaping (String) -> Void) {
        shortcutSettings = settings; shortcutAction = action; registerHotkeys()
    }
    func suspendShortcuts(_ suspended: Bool) {
        if suspended { hotkeys.forEach { UnregisterEventHotKey($0) }; hotkeys.removeAll(); shortcutsSuspended = true }
        else if shortcutsSuspended { shortcutsSuspended = false; registerHotkeys() }
    }
    func shortcutBindings(settings: AppSettings?) -> [String: String] {
        var bindings = AppShortcutBindings.defaults
        if let settings { for (action, value) in settings.shortcuts where bindings[action] != nil { bindings[action] = value } }
        bindings["screenshot"] = AppShortcutBindings.format(code: preferences.screenshotKey, modifiers: preferences.screenshotModifiers ?? preferences.modifiers)
        bindings["recording"] = AppShortcutBindings.format(code: preferences.recordingKey, modifiers: preferences.recordingModifiers ?? preferences.modifiers)
        return bindings
    }
    private func installBindings(_ bindings: [String: String]) throws {
        let parsed = try AppShortcutBindings.validate(bindings), prior = registeredBindings
        func register(_ keys: [String: AppShortcutBindings.Key]) throws {
            for (index, action) in AppShortcutBindings.actions.enumerated() {
                guard let key = keys[action] else { continue }
                var ref: EventHotKeyRef?
                guard RegisterEventHotKey(key.code, key.modifiers, EventHotKeyID(signature: 0x48504153, id: UInt32(index + 1)), GetApplicationEventTarget(), 0, &ref) == noErr, let ref else {
                    throw LibraryError.message("ショートカットが他のアプリで使用されています。別のキーを選んでください。")
                }
                hotkeys.append(ref)
            }
        }
        hotkeys.forEach { UnregisterEventHotKey($0) }; hotkeys.removeAll()
        do { if !shortcutsSuspended { try register(parsed) }; registeredBindings = parsed }
        catch {
            hotkeys.forEach { UnregisterEventHotKey($0) }; hotkeys.removeAll()
            if !shortcutsSuspended { try? register(prior) }; registeredBindings = prior; throw error
        }
    }
    func saveShortcutBindings(_ bindings: [String: String], settings: AppSettings) throws {
        let parsed = try AppShortcutBindings.validate(bindings)
        var next = preferences
        next.screenshotKey = parsed["screenshot"]?.code ?? 0; next.screenshotModifiers = parsed["screenshot"]?.modifiers ?? 0
        next.recordingKey = parsed["recording"]?.code ?? 0; next.recordingModifiers = parsed["recording"]?.modifiers ?? 0
        let prior = shortcutBindings(settings: settings)
        try installBindings(bindings)
        do {
            try writePreferences(next)
            preferences = next; settings.shortcuts = bindings.filter { AppShortcutBindings.defaults[$0.key] != nil }
        } catch { try? installBindings(prior); throw error }
    }
    private func writePreferences(_ value: AssetCapturePreferences) throws {
        try FileManager.default.createDirectory(at: preferencesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: preferencesURL, options: .atomic)
    }
    func savePreferences(_ value: AssetCapturePreferences) throws {
        guard (0...30).contains(value.screenshotToastSeconds) else { throw LibraryError.message("通知時間は0〜30秒で指定してください。") }
        let prior = preferences
        preferences = value
        do { try installBindings(shortcutBindings(settings: shortcutSettings)); try writePreferences(value) }
        catch { preferences = prior; registerHotkeys(); throw error }
    }
    private func content() async throws -> SCShareableContent {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw LibraryError.message("画面収録の許可が必要です。システム設定の「プライバシーとセキュリティ」でHoverPocketを許可して、再度撮影してください。")
        }
        return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }
    private func pendingDirectory() throws -> URL {
        let root = pendingRoot ?? preferencesURL.deletingLastPathComponent().appendingPathComponent("CapturePending")
        let directory = root.appendingPathComponent(UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    func screenshot(folder: String?) async {
        guard !busy, !recording else { return }
        busy = true; toast?.close(); toast = nil
        AssetLibraryRuntime.shared.textInput = false
        AssetLibraryRuntime.shared.closePanel?()
        do {
            try await Task.sleep(for: .milliseconds(180))
            let content = try await content()
            let excluded = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
            var frames: [(NSScreen, CGImage, [CGRect])] = []
            for screen in NSScreen.screens {
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                      let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else { continue }
                let config = SCStreamConfiguration(); config.width = Int(screen.frame.width * screen.backingScaleFactor)
                config.height = Int(screen.frame.height * screen.backingScaleFactor); config.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: excluded), configuration: config)
                let order = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { $0[kCGWindowNumber as String] as? UInt32 }
                let windows = content.windows.filter { $0.isOnScreen && $0.windowLayer == 0 && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier && $0.frame.width > 30 && $0.frame.height > 30 }
                    .sorted { (order.firstIndex(of: $0.windowID) ?? Int.max) < (order.firstIndex(of: $1.windowID) ?? Int.max) }
                let bounds = CGDisplayBounds(display.displayID)
                let rects = windows.map { $0.frame.intersection(bounds).offsetBy(dx: -bounds.minX, dy: -bounds.minY) }.filter { !$0.isNull && $0.width > 0 }
                frames.append((screen, image, rects))
            }
            guard !frames.isEmpty else { throw LibraryError.message("撮影できる画面がありません。") }
            NSApp.activate(ignoringOtherApps: true)
            for (screen, image, rects) in frames {
                let panel = AssetCapturePanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                panel.title = "スクリーンショットを撮影"; panel.hidesOnDeactivate = false
                panel.level = .screenSaver; panel.isOpaque = true; panel.backgroundColor = .black
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; panel.isReleasedWhenClosed = false
                let view = AssetCaptureOverlay(image: image, windowRects: rects)
                view.onCancel = { [weak self] in self?.closeOverlays() }
                view.onSelection = { [weak self, weak panel] rect in
                    guard let self, let panel else { return }
                    for other in overlays where other !== panel { other.orderOut(nil) }
                    let scaleX = CGFloat(image.width) / screen.frame.width, scaleY = CGFloat(image.height) / screen.frame.height
                    let crop = CGRect(x: rect.minX * scaleX, y: rect.minY * scaleY, width: rect.width * scaleX, height: rect.height * scaleY).integral
                    guard let selected = image.cropping(to: crop) else { status = "選択範囲を切り取れません。"; return }
                    let session = AssetEditorSession(image: selected, capture: true)
                    AssetLibraryRuntime.shared.editorSessions.append(session)
                    var saved: LibraryAsset?
                    session.onSave = { [weak self] data, keepOriginal in
                        guard let self else { throw LibraryError.message("撮影が終了しています。") }
                        let directory = try pendingDirectory()
                        let name = "スクリーンショット " + LibraryFormat.now().replacingOccurrences(of: ":", with: "-")
                        let file = directory.appendingPathComponent(name + ".png")
                        try data.write(to: file, options: .atomic)
                        if keepOriginal { try AssetMedia.png(selected).write(to: directory.appendingPathComponent(name + " 元画像.png"), options: .atomic) }
                        try AssetPendingCapture(folder: folder, files: [file.lastPathComponent] + (keepOriginal ? [name + " 元画像.png"] : [])).write(to: directory)
                        let store = try await AssetLibraryRuntime.shared.store()
                        let result = try await store.importFile(file, folder: folder)
                        guard let id = result.assetId, result.status == "saved" || result.status == "duplicate" else { throw LibraryError.message("撮影画像を登録できません。装飾を保持しています。") }
                        if keepOriginal { _ = try await store.importFile(directory.appendingPathComponent(name + " 元画像.png"), folder: folder) }
                        saved = try await store.get(id)
                        try? FileManager.default.trashItem(at: directory, resultingItemURL: nil)
                        AssetLibraryRuntime.shared.notifyChange(); status = "スクリーンショットを保存しました。"
                        return saved
                    }
                    let sessionID = session.id
                    session.onFinish = { [weak self] in
                        guard let self else { return }
                        AssetLibraryRuntime.shared.editorSessions.removeAll { $0.id == sessionID }
                        closeOverlays()
                        if let saved { Task { @MainActor in await self.showToast(saved, screen: screen) } }
                    }
                    view.showEditor(session, selection: rect)
                }
                panel.contentView = view; overlays.append(panel); panel.makeKeyAndOrderFront(nil)
                panel.makeFirstResponder(view)
            }
        } catch { status = error.localizedDescription; closeOverlays(); showFailure(status) }
    }
    private func closeOverlays() { overlays.forEach { $0.orderOut(nil) }; overlays.removeAll(); busy = false }

    func verifyScreenshotPresentation() async throws -> [String] {
        guard CommandLine.arguments.contains("--verify-asset-library"), !busy, !recording else {
            throw LibraryError.message("screenshot presentation verification precondition")
        }
        defer { closeOverlays() }
        NSApp.deactivate()
        try await Task.sleep(for: .milliseconds(100))
        guard !NSApp.isActive else { throw LibraryError.message("capture verification must start with the app inactive") }
        await screenshot(folder: nil)
        try await Task.sleep(for: .milliseconds(100))
        guard busy, !overlays.isEmpty, overlays.allSatisfy({ $0.isVisible }),
              let panel = overlays.first(where: { $0.isKeyWindow }),
              let view = panel.contentView as? AssetCaptureOverlay else {
            throw LibraryError.message("screenshot overlay did not become visible and receive keyboard focus")
        }
        NSApp.deactivate()
        try await Task.sleep(for: .milliseconds(100))
        guard overlays.allSatisfy({ $0.isVisible && !$0.hidesOnDeactivate }) else {
            throw LibraryError.message("screenshot overlay disappeared when the app became inactive")
        }
        guard let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) else {
            throw LibraryError.message("capture cancel event missing")
        }
        view.keyDown(with: escape)
        guard overlays.isEmpty, !busy else { throw LibraryError.message("capture cancellation did not release the session") }
        return ["inactive app capture presents a focused overlay", "overlay survives application deactivation", "Escape cancels and releases the capture session"]
    }
    private func showToast(_ asset: LibraryAsset, screen: NSScreen) async {
        guard preferences.screenshotToastSeconds > 0 else { return }
        do {
            let store = try await AssetLibraryRuntime.shared.store(), copy = try await store.copyOut(asset.id)
            let image = try AssetMedia.image(copy, maximum: 600)
            toast = AssetScreenshotToast(image: image, file: copy, seconds: preferences.screenshotToastSeconds, screen: screen)
            toast?.show()
        } catch { status = "画像は保存済みですが、通知を準備できませんでした。" }
    }
    func toggleRecording(folder: String?) async {
        if recording { await stopRecording(); return }
        guard !busy else { return }; busy = true
        toast?.close(); toast = nil; AssetLibraryRuntime.shared.textInput = false; AssetLibraryRuntime.shared.closePanel?()
        do {
            let content = try await content()
            let panel = NSAlert(); panel.messageText = "画面収録の対象を選択"
            panel.informativeText = "停止は \(preferences.recordingShortcut) またはメニューバーの「収録を停止して保存」です。"
            panel.addButton(withTitle: "収録開始"); panel.addButton(withTitle: "キャンセル")
            let chooser = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 380, height: 28))
            let windows = content.windows.filter { $0.isOnScreen && $0.windowLayer == 0 && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier && $0.frame.width > 30 }
            for (index, _) in content.displays.enumerated() { chooser.addItem(withTitle: "画面 \(index + 1)") }
            for window in windows { chooser.addItem(withTitle: (window.owningApplication?.applicationName ?? "アプリ") + " — " + (window.title ?? "ウィンドウ")) }
            panel.accessoryView = chooser
            guard panel.runModal() == .alertFirstButtonReturn else { busy = false; return }
            let filter: SCContentFilter, size: CGSize
            if chooser.indexOfSelectedItem < content.displays.count {
                let display = content.displays[chooser.indexOfSelectedItem]
                let exclude = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
                filter = SCContentFilter(display: display, excludingWindows: exclude); size = CGSize(width: display.width, height: display.height)
            } else {
                let window = windows[chooser.indexOfSelectedItem - content.displays.count]
                filter = SCContentFilter(desktopIndependentWindow: window); size = window.frame.size
            }
            if preferences.microphone, !(await AVCaptureDevice.requestAccess(for: .audio)) { throw LibraryError.message("マイクが許可されていません。撮影・収録の設定でマイクをオフにするか、システム設定で許可してください。") }
            try await beginRecording(filter: filter, size: size, folder: folder, name: nil,
                systemAudio: preferences.systemAudio, microphone: preferences.microphone)
            busy = false
        } catch { busy = false; status = error.localizedDescription; showFailure(status) }
    }
    func toggleRegionRecording(folder: String?) async {
        if recording { await stopRecording(); return }
        guard !busy else { return }; busy = true
        toast?.close(); toast = nil; AssetLibraryRuntime.shared.textInput = false; AssetLibraryRuntime.shared.closePanel?()
        defer { closeOverlays() }
        do {
            try await Task.sleep(for: .milliseconds(180))
            let content = try await content()
            let excluded = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
            var choices: [(NSScreen, SCDisplay, CGImage)] = []
            for screen in NSScreen.screens {
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                      let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else { continue }
                let config = SCStreamConfiguration()
                config.width = Int(screen.frame.width * screen.backingScaleFactor)
                config.height = Int(screen.frame.height * screen.backingScaleFactor); config.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: excluded), configuration: config)
                choices.append((screen, display, image))
            }
            guard !choices.isEmpty else { throw LibraryError.message("収録できる画面がありません。") }
            NSApp.activate(ignoringOtherApps: true)
            let selected: (CGDirectDisplayID, CGRect, CGFloat)? = await withCheckedContinuation { continuation in
                var resolved = false
                for (screen, display, image) in choices {
                    let panel = AssetCapturePanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    panel.title = "収録範囲を選択"; panel.hidesOnDeactivate = false; panel.level = .screenSaver
                    panel.isOpaque = true; panel.backgroundColor = .black
                    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; panel.isReleasedWhenClosed = false
                    let view = AssetCaptureOverlay(image: image, windowRects: [])
                    view.onCancel = { if !resolved { resolved = true; continuation.resume(returning: nil) } }
                    view.onSelection = { rect in
                        guard !resolved else { return }; resolved = true
                        continuation.resume(returning: (display.displayID, rect.intersection(CGRect(origin: .zero, size: screen.frame.size)), screen.backingScaleFactor))
                    }
                    panel.contentView = view; overlays.append(panel); panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(view)
                }
            }
            closeOverlays(); busy = true
            guard let (displayID, rect, scale) = selected else { status = "範囲収録をキャンセルしました。"; return }
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw LibraryError.message("選択した画面が見つかりません。") }
            guard rect.width >= 3, rect.height >= 3 else { throw LibraryError.message("収録範囲を広げてください。") }
            if preferences.microphone, !(await AVCaptureDevice.requestAccess(for: .audio)) { throw LibraryError.message("マイクが許可されていません。撮影設定でマイクをオフにするか、システム設定で許可してください。") }
            try await Task.sleep(for: .milliseconds(180))
            try await beginRecording(filter: SCContentFilter(display: display, excludingWindows: excluded),
                size: CGSize(width: rect.width * scale, height: rect.height * scale), folder: folder, name: nil,
                systemAudio: preferences.systemAudio, microphone: preferences.microphone, sourceRect: rect)
        } catch { status = error.localizedDescription; showFailure(status) }
    }
    @discardableResult
    func stopRecording(reason: String? = nil, reportFailure: Bool = true) async -> LibraryAsset? {
        guard let recorder, !busy else { return nil }; busy = true
        defer { self.recorder = nil; recording = false; busy = false }
        lastRecordingAsset = nil; lastRecordingError = nil
        do {
            let url = try await recorder.stop()
            try AssetPendingCapture(folder: recordingFolder, files: [url.lastPathComponent]).write(to: url.deletingLastPathComponent())
            let store = try await libraryStore()
            let result = try await store.importFile(url, folder: recordingFolder)
            guard let id = result.assetId, result.status == "saved" || result.status == "duplicate" else { throw LibraryError.message("収録ファイルを登録できません。保存待ちフォルダへ保持しています。") }
            if let recordingName { try await store.update(ids: [id], operation: "rename", value: recordingName) }
            guard let saved = try await store.get(id) else { throw LibraryVoiceError.failed("recording_save_failed") }
            _ = try await store.path(saved, verifyHash: true)
            lastRecordingAsset = saved
            status = (reason.map { $0 + " " } ?? "") + "画面収録を保存しました。"; AssetLibraryRuntime.shared.notifyChange()
            if let recordDirectory { try? FileManager.default.trashItem(at: recordDirectory, resultingItemURL: nil) }
        } catch {
            lastRecordingError = "recording_save_failed"
            status = error.localizedDescription + " 収録ファイルは保存待ちフォルダに保持しています。"
            if reportFailure { showFailure(status) }
        }
        return lastRecordingAsset
    }
    func screenshotForVoice(filter: SCContentFilter, folder: String?, name: String?) async throws -> LibraryAsset {
        guard !busy, !recording else { throw LibraryVoiceError.failed("capture_busy") }
        try Task.checkCancellation()
        busy = true; defer { busy = false }
        toast?.close(); toast = nil
        let config = SCStreamConfiguration()
        config.width = max(1, Int(filter.contentRect.width * CGFloat(filter.pointPixelScale)))
        config.height = max(1, Int(filter.contentRect.height * CGFloat(filter.pointPixelScale)))
        config.showsCursor = false; config.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        try Task.checkCancellation()
        let directory = try pendingDirectory()
        let file = directory.appendingPathComponent("スクリーンショット " + LibraryFormat.now().replacingOccurrences(of: ":", with: "-") + ".png")
        try AssetMedia.png(image).write(to: file, options: .atomic)
        try AssetPendingCapture(folder: folder, files: [file.lastPathComponent]).write(to: directory)
        let store = try await libraryStore(), result = try await store.importFile(file, folder: folder)
        guard let id = result.assetId, ["saved", "duplicate"].contains(result.status) else { throw LibraryVoiceError.failed("screenshot_save_failed") }
        if let name { try await store.update(ids: [id], operation: "rename", value: name) }
        guard let saved = try await store.get(id) else { throw LibraryVoiceError.failed("screenshot_save_failed") }
        _ = try await store.path(saved, verifyHash: true)
        try? FileManager.default.trashItem(at: directory, resultingItemURL: nil)
        AssetLibraryRuntime.shared.notifyChange(); status = "スクリーンショットを保存しました。"
        return saved
    }
    func startRecordingForVoice(filter: SCContentFilter, folder: String?, name: String?, systemAudio: Bool, microphone: Bool) async throws -> String {
        guard !busy, !recording else { throw LibraryVoiceError.failed("capture_busy") }
        try Task.checkCancellation()
        busy = true; defer { busy = false }
        toast?.close(); toast = nil
        if microphone, !(await AVCaptureDevice.requestAccess(for: .audio)) { throw LibraryVoiceError.failed("microphone_permission_required") }
        try Task.checkCancellation()
        try await beginRecording(filter: filter, size: filter.contentRect.size, folder: folder, name: name,
            systemAudio: systemAudio, microphone: microphone)
        return recordingID!
    }
    private func beginRecording(filter: SCContentFilter, size: CGSize, folder: String?, name: String?, systemAudio: Bool, microphone: Bool, sourceRect: CGRect? = nil) async throws {
        let directory = try pendingDirectory()
        let recorder = try AssetScreenRecorder(directory: directory, systemAudio: systemAudio, microphone: microphone)
        recorder.onFailure = { [weak self] text in
            Task { @MainActor in await self?.stopRecording(reason: text, reportFailure: false) }
        }
        do {
            try await recorder.start(filter: filter, size: size, sourceRect: sourceRect)
            try Task.checkCancellation()
        } catch {
            _ = try? await recorder.stop()
            throw error
        }
        self.recorder = recorder; recordDirectory = directory; recordingFolder = folder; recordingName = name
        recordingID = UUID().uuidString.lowercased(); lastRecordingAsset = nil; lastRecordingError = nil
        recording = true; status = "画面を収録中です。\(preferences.recordingShortcut)または音声で停止して保存します。"
    }
    func stopRecordingForVoice(id: String) async throws -> LibraryAsset {
        guard recording, id == recordingID, !busy else { throw LibraryVoiceError.failed("recording_changed") }
        try Task.checkCancellation()
        guard let saved = await stopRecording(reportFailure: false) else { throw LibraryVoiceError.failed("recording_save_failed") }
        return saved
    }
    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 290), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "撮影・収録の設定"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: AssetCaptureSettings(controller: self))
            window.center(); settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func openPending() {
        let root = preferencesURL.deletingLastPathComponent().appendingPathComponent("CapturePending")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); NSWorkspace.shared.open(root)
    }
    func retryPending() async {
        guard !busy, !recording else { return }; busy = true; defer { busy = false }
        do {
            let root = preferencesURL.deletingLastPathComponent().appendingPathComponent("CapturePending")
            let store = try await AssetLibraryRuntime.shared.store()
            let count = try await AssetPendingCapture.retry(root: root, store: store)
            status = "保存待ちの撮影 \(count)件を登録しました。"; AssetLibraryRuntime.shared.notifyChange()
        } catch { status = error.localizedDescription + " 保存待ちファイルは保持されています。" }
    }
    private func showFailure(_ message: String) {
        let alert = NSAlert(); alert.messageText = "撮影・収録を完了できませんでした"; alert.informativeText = message; alert.runModal()
    }
}

private struct AssetCaptureSettings: View {
    @ObservedObject var controller: AssetCaptureController
    @State private var value = AssetCapturePreferences()
    @State private var error = ""
    var body: some View {
        Form {
            Toggle("システム音を収録", isOn: $value.systemAudio)
            Toggle("マイクを収録", isOn: $value.microphone)
            Stepper("スクショ通知: \(value.screenshotToastSeconds)秒（0で無効）", value: $value.screenshotToastSeconds, in: 0...30)
            Picker("撮影ショートカット", selection: $value.screenshotKey) {
                Text("⌘⌥S").tag(UInt32(kVK_ANSI_S)); Text("⌘⌥1").tag(UInt32(kVK_ANSI_1))
            }
            Picker("収録ショートカット", selection: $value.recordingKey) {
                Text("⌘⌥R").tag(UInt32(kVK_ANSI_R)); Text("⌘⌥2").tag(UInt32(kVK_ANSI_2))
            }
            HStack { Button("設定を保存") { do { try controller.savePreferences(value); error = "保存しました。" } catch { self.error = error.localizedDescription } }; Button("保存待ちフォルダ") { controller.openPending() } }
            Button("保存待ちの撮影を再登録") { Task { await controller.retryPending() } }.disabled(controller.busy || controller.recording)
            Text(error.isEmpty ? controller.status : error).font(.caption)
        }.padding(20).onAppear { value = controller.preferences }
    }
}

private final class AssetCapturePanel: NSPanel { override var canBecomeKey: Bool { true } }

@MainActor
private final class AssetCaptureOverlay: NSView {
    let image: CGImage
    let windowRects: [CGRect]
    var onCancel: (() -> Void)?
    var onSelection: ((CGRect) -> Void)?
    private var selection = CGRect.zero
    private var start: CGPoint?
    private var editor: NSView?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(image: CGImage, windowRects: [CGRect]) { self.image = image; self.windowRects = windowRects; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseMoved], owner: self)); super.updateTrackingAreas()
    }
    override func draw(_ dirtyRect: NSRect) {
        NSImage(cgImage: image, size: bounds.size).draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSColor.black.withAlphaComponent(0.30).setFill()
        let path = NSBezierPath(rect: bounds); path.appendRect(selection); path.windingRule = .evenOdd; path.fill()
        NSColor.systemBlue.setStroke(); let border = NSBezierPath(rect: selection.insetBy(dx: 1, dy: 1)); border.lineWidth = 2; border.stroke()
        if editor == nil {
            ("クリックでウィンドウ／画面を選択・ドラッグで範囲指定・Escで取消" as NSString).draw(at: CGPoint(x: 24, y: 32), withAttributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.white, .backgroundColor: NSColor.black.withAlphaComponent(0.6)])
        }
    }
    override func mouseMoved(with event: NSEvent) {
        guard editor == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = windowRects.first { $0.contains(point) } ?? bounds; needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) { if editor == nil { start = convert(event.locationInWindow, from: nil) } }
    override func mouseDragged(with event: NSEvent) {
        guard editor == nil, let start else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(start.x-point.x), height: abs(start.y-point.y)).intersection(bounds); needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard editor == nil else { return }; start = nil
        if selection.width < 3 || selection.height < 3 { mouseMoved(with: event) }
        onSelection?(selection.isEmpty ? bounds : selection)
    }
    override func keyDown(with event: NSEvent) {
        guard !event.isARepeat, editor == nil else { return }
        if event.keyCode == 53 { onCancel?() }
        else if event.keyCode == 36 { onSelection?(selection.isEmpty ? bounds : selection) }
    }
    func showEditor(_ session: AssetEditorSession, selection: CGRect) {
        let canvas = NSHostingView(rootView: AssetDrawingCanvas(session: session))
        canvas.frame = selection; addSubview(canvas); editor = canvas
        let toolbar = NSHostingView(rootView: AssetAnnotationEditor(session: session, showsCanvas: false))
        let width = min(bounds.width - 16, max(760, selection.width)), height: CGFloat = 100
        let y = selection.minY >= height ? selection.minY - height : min(bounds.height - height, selection.maxY + height <= bounds.height ? selection.maxY : selection.minY)
        toolbar.frame = CGRect(x: min(max(8, selection.midX - width/2), bounds.width - width - 8), y: max(0, y), width: width, height: height)
        addSubview(toolbar); needsDisplay = true
        DispatchQueue.main.async { [weak session] in if let canvas = session?.canvas { canvas.window?.makeFirstResponder(canvas) } }
    }
}
