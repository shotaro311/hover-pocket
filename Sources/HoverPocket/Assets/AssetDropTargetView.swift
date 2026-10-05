import AppKit

@MainActor
final class AssetDropTargetView: NSView {
    init(content: NSView) {
        super.init(frame: content.frame)
        content.autoresizingMask = [.width, .height]; addSubview(content)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard AssetLibraryRuntime.shared.canAcceptDrop?() == true else { return [] }
        AssetLibraryRuntime.shared.openForDrop?(); return .copy
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard AssetLibraryRuntime.shared.canAcceptDrop?() == true,
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        AssetLibraryRuntime.shared.receiveDrop(urls); return true
    }
}
