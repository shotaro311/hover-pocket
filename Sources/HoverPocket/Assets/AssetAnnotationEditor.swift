import AppKit
import Combine
import SwiftUI
import ImageIO

enum AssetDrawingTool: String, CaseIterable {
    case pen, text, rectangle, ellipse, arrow, move, eraser
    var symbol: String {
        switch self { case .pen: "pencil.tip"; case .text: "textformat"; case .rectangle: "rectangle";
        case .ellipse: "oval"; case .arrow: "arrow.up.right"; case .move: "arrow.up.and.down.and.arrow.left.and.right"; case .eraser: "eraser" }
    }
    var label: String {
        switch self { case .pen: "ペン"; case .text: "文字"; case .rectangle: "四角"; case .ellipse: "楕円";
        case .arrow: "矢印"; case .move: "移動"; case .eraser: "消しゴム" }
    }
}
struct AssetAnnotation {
    var tool: AssetDrawingTool
    var points: [CGPoint]
    var color: NSColor
    var width: CGFloat
    var text = ""
    var bounds: CGRect {
        guard let first = points.first else { return .zero }
        if tool == .text {
            return CGRect(origin: first, size: (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: max(16, width * 6))])).insetBy(dx: -8, dy: -8)
        }
        return points.reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: CGSize(width: 1, height: 1))) }
            .insetBy(dx: -max(12, width * 2), dy: -max(12, width * 2))
    }
}

@MainActor
final class AssetEditorSession: ObservableObject, Identifiable {
    let id = UUID()
    let image: CGImage
    @Published var annotations: [AssetAnnotation] = []
    @Published var tool = AssetDrawingTool.pen
    @Published var color = Color.red
    @Published var lineWidth: Double = 4
    @Published var saving = false
    @Published var error = ""
    @Published var keepOriginal = false
    @Published var textEditing = false
    var onSave: ((Data, Bool) async throws -> LibraryAsset?)?
    var onFinish: (() -> Void)?
    private var undo: [[AssetAnnotation]] = []
    private var redo: [[AssetAnnotation]] = []
    private var completion: CheckedContinuation<LibraryAsset?, Never>?
    weak var canvas: AssetDrawingView?
    let capture: Bool
    init(image: CGImage, capture: Bool = false) { self.image = image; self.capture = capture }
    static func load(url: URL, asset: LibraryAsset, store: AssetLibraryStore) async throws -> AssetEditorSession {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
              Double(width) * Double(height) <= 32_000_000 else { throw LibraryError.message("画像編集は32MPまでです。原本は保持されています。") }
        let session = AssetEditorSession(image: try AssetMedia.image(url, maximum: max(width, height)))
        session.onSave = { data, _ in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HoverPocket-Edit-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = URL(fileURLWithPath: asset.name).deletingPathExtension().lastPathComponent + " 編集.png"
            let url = directory.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            let result = try await store.importFile(url.resolvingSymlinksInPath(), folder: asset.folderIds.first, internet: asset.internetOrigin)
            guard let id = result.assetId, ["saved", "duplicate"].contains(result.status) else { throw LibraryError.message("編集画像を登録できませんでした。編集内容は保持しています。") }
            for category in asset.folderIds + asset.tagIds { try await store.update(ids: [id], operation: "classify", value: category) }
            return try await store.get(id)
        }
        return session
    }
    func waitForResult() async -> LibraryAsset? { await withCheckedContinuation { completion = $0 } }
    func checkpoint() { undo.append(annotations); if undo.count > 100 { undo.removeFirst() }; redo = [] }
    func undoDrawing() { guard !saving, let old = undo.popLast() else { return }; redo.append(annotations); annotations = old }
    func redoDrawing() { guard !saving, let next = redo.popLast() else { return }; undo.append(annotations); annotations = next }
    @discardableResult func cancel() -> Bool {
        guard !saving else { return false }
        if !annotations.isEmpty || textEditing {
            let alert = NSAlert(); alert.messageText = "保存していない注釈を取り消しますか？"
            alert.addButton(withTitle: "取り消す"); alert.addButton(withTitle: "編集を続ける")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        completion?.resume(returning: nil); completion = nil; onFinish?(); return true
    }
    func save() {
        guard !saving, !textEditing else { return }
        saving = true; error = ""
        Task { @MainActor in
            do {
                guard let onSave else { throw LibraryError.message("保存先を準備できません。") }
                let result = try await onSave(render(), keepOriginal)
                completion?.resume(returning: result); completion = nil; onFinish?()
            } catch { self.error = error.localizedDescription; saving = false }
        }
    }
    func render() throws -> Data {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: image.width, pixelsHigh: image.height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw LibraryError.message("画像を描画できません。") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        let cg = context.cgContext
        cg.translateBy(x: 0, y: CGFloat(image.height)); cg.scaleBy(x: 1, y: -1)
        AssetDrawingView.paint(image: image, annotations: annotations, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw LibraryError.message("PNGを保存できません。") }
        return data
    }
}

struct AssetAnnotationEditor: View {
    @ObservedObject var session: AssetEditorSession
    var showsCanvas = true
    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 5) { tools; options; history; finish }
                VStack(spacing: 5) { HStack(spacing: 5) { tools; history }; HStack(spacing: 5) { options; Spacer(); finish } }
            }
            .padding(8)
            if showsCanvas { AssetDrawingCanvas(session: session) }
            if !session.error.isEmpty { Text(session.error).font(.caption).foregroundStyle(.orange).padding(6) }
        }
        .background(Color(red: 0.10, green: 0.11, blue: 0.13))
        .foregroundStyle(.white)
        .disabled(session.saving)
    }
    private var tools: some View {
        ForEach(AssetDrawingTool.allCases, id: \.self) { tool in
            Button { session.canvas?.commitText(); session.tool = tool } label: {
                Image(systemName: tool.symbol).frame(width: 20, height: 22)
            }.buttonStyle(.bordered).tint(session.tool == tool ? .blue : .gray).help(tool.label)
        }
    }
    private var options: some View {
        HStack(spacing: 4) {
            ColorPicker("色", selection: $session.color).labelsHidden().frame(width: 28)
            Slider(value: $session.lineWidth, in: 1...24).frame(width: 66).help("線の太さ")
            if session.capture { Toggle("元画像も保存", isOn: $session.keepOriginal).font(.caption) }
        }
    }
    private var history: some View {
        HStack(spacing: 4) {
            Button { session.undoDrawing() } label: { Image(systemName: "arrow.uturn.backward") }.help("元に戻す ⌘Z")
            Button { session.redoDrawing() } label: { Image(systemName: "arrow.uturn.forward") }.help("やり直す ⇧⌘Z")
        }
    }
    private var finish: some View {
        HStack(spacing: 5) {
            Button { session.cancel() } label: { Image(systemName: "xmark") }.help("取消")
            Button { session.canvas?.commitText(); session.save() } label: {
                if session.saving { ProgressView().controlSize(.small) } else { Image(systemName: "checkmark") }
            }.tint(.blue).help("保存")
        }
    }
}
struct AssetDrawingCanvas: NSViewRepresentable {
    @ObservedObject var session: AssetEditorSession
    func makeNSView(context: Context) -> AssetDrawingView { let view = AssetDrawingView(session: session); session.canvas = view; return view }
    func updateNSView(_ view: AssetDrawingView, context: Context) { view.needsDisplay = true }
}

@MainActor
final class AssetDrawingView: NSView, NSTextFieldDelegate {
    let session: AssetEditorSession
    private var activeIndex: Int?
    private var lastPoint: CGPoint?
    private var textField: NSTextField?
    private var textOrigin: CGPoint?
    private var clickCheckpoint: [AssetAnnotation]?
    private var selectedAnnotation: Int?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(session: AssetEditorSession) { self.session = session; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    var imageRect: CGRect {
        let scale = min(bounds.width / CGFloat(session.image.width), bounds.height / CGFloat(session.image.height))
        let size = CGSize(width: CGFloat(session.image.width) * scale, height: CGFloat(session.image.height) * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }
    private func pixel(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil), rect = imageRect
        return CGPoint(x: (point.x - rect.minX) * CGFloat(session.image.width) / max(1, rect.width),
            y: (point.y - rect.minY) * CGFloat(session.image.height) / max(1, rect.height))
    }
    override func draw(_ dirtyRect: NSRect) { Self.paint(image: session.image, annotations: session.annotations, in: imageRect) }
    static func paint(image: CGImage, annotations: [AssetAnnotation], in rect: CGRect) {
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = rect.width / CGFloat(image.width)
        context.translateBy(x: rect.minX, y: rect.minY); context.scaleBy(x: scale, y: scale)
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.clip(to: bounds)
        NSImage(cgImage: image, size: bounds.size).draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        for a in annotations {
            guard let first = a.points.first, let last = a.points.last else { continue }
            a.color.setStroke(); a.color.setFill()
            let path = NSBezierPath(); path.lineWidth = a.width; path.lineCapStyle = .round; path.lineJoinStyle = .round
            let rect = CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x-first.x), height: abs(last.y-first.y))
            switch a.tool {
            case .rectangle: path.appendRect(rect)
            case .ellipse: path.appendOval(in: rect)
            case .text:
                (a.text as NSString).draw(at: first, withAttributes: [.font: NSFont.systemFont(ofSize: max(16, a.width * 6)), .foregroundColor: a.color])
                continue
            default:
                path.move(to: first); for point in a.points.dropFirst() { path.line(to: point) }
                if a.tool == .arrow {
                    let angle = atan2(last.y-first.y, last.x-first.x), length = max(14, a.width * 4)
                    for offset in [-CGFloat.pi/6, CGFloat.pi/6] {
                        path.move(to: last); path.line(to: CGPoint(x: last.x-length*cos(angle+offset), y: last.y-length*sin(angle+offset)))
                    }
                }
            }
            path.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard !session.saving else { return }
        if event.clickCount == 2, session.capture, session.tool != .text, textField == nil {
            if let clickCheckpoint { session.annotations = clickCheckpoint }; session.save(); return
        }
        commitText(); window?.makeFirstResponder(self)
        guard imageRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        let point = pixel(event); clickCheckpoint = session.annotations
        session.checkpoint(); lastPoint = point
        if session.tool == .text {
            let local = convert(event.locationInWindow, from: nil)
            let field = NSTextField(frame: CGRect(x: local.x, y: local.y, width: min(260, bounds.width - local.x), height: 32))
            field.delegate = self; field.placeholderString = "文字を入力"; addSubview(field)
            textField = field; textOrigin = point; session.textEditing = true; window?.makeFirstResponder(field); return
        }
        if session.tool == .move || session.tool == .eraser {
            activeIndex = session.annotations.lastIndex { $0.bounds.contains(point) }
            selectedAnnotation = activeIndex
            if session.tool == .eraser, let index = activeIndex { session.annotations.remove(at: index); activeIndex = nil }
        } else {
            session.annotations.append(AssetAnnotation(tool: session.tool, points: [point, point], color: NSColor(session.color), width: session.lineWidth))
            activeIndex = session.annotations.count - 1
        }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard !session.saving, let index = activeIndex, session.annotations.indices.contains(index) else { return }
        let point = pixel(event)
        if session.tool == .move, let lastPoint {
            session.annotations[index].points = session.annotations[index].points.map { CGPoint(x: $0.x + point.x-lastPoint.x, y: $0.y+point.y-lastPoint.y) }
        } else if session.tool == .pen { session.annotations[index].points.append(point) }
        else { session.annotations[index].points[1] = point }
        lastPoint = point; needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) { activeIndex = nil; lastPoint = nil }
    func commitText() {
        guard let field = textField, let point = textOrigin else { return }
        if !field.stringValue.isEmpty { session.annotations.append(AssetAnnotation(tool: .text, points: [point], color: NSColor(session.color), width: session.lineWidth, text: field.stringValue)) }
        field.removeFromSuperview(); textField = nil; textOrigin = nil; session.textEditing = false; needsDisplay = true
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        if command == #selector(NSResponder.insertNewline(_:)) { commitText(); window?.makeFirstResponder(self); return true }
        if command == #selector(NSResponder.cancelOperation(_:)) { textField?.removeFromSuperview(); textField = nil; session.textEditing = false; return true }
        return false
    }
    override func keyDown(with event: NSEvent) {
        guard !session.saving, !event.isARepeat else { return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
            if event.modifierFlags.contains(.shift) { session.redoDrawing() } else { session.undoDrawing() }; return
        }
        if event.keyCode == 53 { session.cancel() }
        else if event.keyCode == 36 { session.save() }
        else if [51, 117].contains(event.keyCode), let index = selectedAnnotation, session.annotations.indices.contains(index) {
            session.checkpoint(); session.annotations.remove(at: index); selectedAnnotation = nil; needsDisplay = true
        }
        else { super.keyDown(with: event) }
    }
}
