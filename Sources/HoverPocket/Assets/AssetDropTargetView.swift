import AppKit

@MainActor
final class AssetDropTargetView: NSView {
    init(content: NSView) {
        super.init(frame: content.frame)
        content.autoresizingMask = [.width, .height]; addSubview(content)
        registerForDraggedTypes(AssetIncomingDrop.types)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard AssetLibraryRuntime.shared.canAcceptDrop?() == true, AssetIncomingDrop.accepts(sender.draggingPasteboard) else { return [] }
        AssetLibraryRuntime.shared.openForDrop?(); return .copy
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard AssetLibraryRuntime.shared.canAcceptDrop?() == true else { return false }
        return AssetIncomingDrop.receive(sender.draggingPasteboard) { urls, error in
            if !urls.isEmpty { AssetLibraryRuntime.shared.receiveDrop(urls) }
            if let error { AssetDropOverlay.shared.showError(error) }
        }
    }
}
