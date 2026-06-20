@preconcurrency import AVFoundation
import AppKit
import QuartzCore
import SwiftUI

struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession
    let onReady: @MainActor () -> Void

    func makeNSView(context: Context) -> CameraPreviewNSView {
        let view = CameraPreviewNSView(session: session)
        DispatchQueue.main.async {
            onReady()
        }
        return view
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        nsView.updateSession(session)
    }
}

final class CameraPreviewNSView: NSView {
    private let previewLayer = AVCaptureVideoPreviewLayer()

    init(session: AVCaptureSession) {
        super.init(frame: .zero)
        wantsLayer = true

        let rootLayer = CALayer()
        rootLayer.backgroundColor = NSColor.black.cgColor
        layer = rootLayer

        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
        rootLayer.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func updateSession(_ session: AVCaptureSession) {
        if previewLayer.session !== session {
            previewLayer.session = session
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }
}
