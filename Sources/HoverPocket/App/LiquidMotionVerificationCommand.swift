import AppKit
import Foundation
import ScreenCaptureKit
import WebKit

@MainActor
enum LiquidMotionVerificationCommand {
    static func verifyGeometry() throws {
        func check(_ condition: Bool, _ code: String) throws {
            guard condition else { throw PanelSoakVerificationError.failed("liquid_geometry_" + code) }
        }
        for size in PanelSizeOption.allCases {
            for voiceHeight: CGFloat in [0, 74, 280] {
                let base = PanelLayout.previewSize(for: size)
                for headerHeight: CGFloat in [24, 38] {
                    for notchWidth: CGFloat in [0, 185, 246] {
                        let metrics = PanelAttachmentMetrics(headerHeight: headerHeight, notchWidth: notchWidth)
                        let envelope = CGRect(x: 19, y: 27, width: base.width + 16,
                                              height: base.height + voiceHeight + metrics.contentTop)
                        let expectedBody = CGRect(x: 27, y: 27 + metrics.contentTop,
                                                  width: base.width, height: base.height + voiceHeight)
                        for blend in [0.0, 0.25, 0.5, 0.75, 0.99, 1.0] {
                            for origin: CGFloat in [108, 168, 200, 308] {
                                var priorWidth: CGFloat = 0, priorHeight: CGFloat = 0
                                for step in 0...100 {
                                    let shape = LiquidPanelGeometry.shape(progress: Double(step) / 100,
                                        panelRect: envelope, originWidth: origin, attachment: metrics, attachmentBlend: blend)
                                    try check(shape.rect.width >= priorWidth && shape.rect.height >= priorHeight, "monotonic")
                                    try check(abs(shape.rect.midX - envelope.midX) < 0.0001
                                              && abs(shape.rect.minY - shape.neckRect.maxY) < 0.0001, "connected_origin")
                                    try check(shape.topRadius + shape.bottomRadius <= shape.rect.height + 0.0001, "corner_bounds")
                                    let spread = (shape.rect.width - shape.neckRect.width) / 2
                                    try check(shape.topRadius + shape.joinRadius <= spread + 0.0001, "join_no_fold")
                                    try check(shape.upperRadius + shape.joinRadius <= shape.neckRect.height + 0.0001, "vertical_neck")
                                    try check(envelope.insetBy(dx: -0.001, dy: -0.001).contains(shape.path.boundingBoxOfPath), "path_contained")
                                    try check((0...1).contains(shape.contentOpacity), "opacity")
                                    priorWidth = shape.rect.width; priorHeight = shape.rect.height
                                }
                                let closed = LiquidPanelGeometry.shape(progress: 0, panelRect: envelope,
                                    originWidth: origin, attachment: metrics, attachmentBlend: blend)
                                let open = LiquidPanelGeometry.shape(progress: 1, panelRect: envelope,
                                    originWidth: origin, attachment: metrics, attachmentBlend: blend)
                                try check(abs(closed.rect.height - headerHeight / 2 * blend) < 0.0001 && closed.contentOpacity == 0
                                          && closed.fillOpacity == (notchWidth > 0 ? 1 : 0), "closed_endpoint")
                                if blend == 1 {
                                    let neckWidth = min(base.width, notchWidth > 0 ? notchWidth + metrics.pixelOverlap * 2 : PanelLayout.miniBarExpandedWidth)
                                    let notch = CGRect(x: envelope.midX - neckWidth / 2, y: envelope.minY,
                                                       width: neckWidth, height: headerHeight)
                                    try check(closed.path.boundingBoxOfPath == notch && closed.upperRadius == 0
                                              && closed.bottomRadius == 10, "cover_closed_notch")
                                }
                                try check(open.rect == expectedBody && open.bottomRadius == 18 && open.contentOpacity == 1, "open_endpoint")
                                try check(open.path.contains(CGPoint(x: envelope.midX, y: expectedBody.midY)), "open_path")
                                if open.neckRect.height > 0 {
                                    try check(open.path.contains(CGPoint(x: envelope.midX, y: open.neckRect.midY)), "connected_neck")
                                } else {
                                    try check(!open.path.contains(CGPoint(x: envelope.midX, y: envelope.minY + headerHeight * 0.75)), "hardware_notch_empty")
                                }
                                let menuPoint = CGPoint(x: expectedBody.minX + 10, y: envelope.minY + headerHeight / 2)
                                if blend == 0 { try check(!open.path.contains(menuPoint), "menu_visible") }
                                if blend == 1 { try check(open.path.contains(menuPoint), "menu_covered") }
                            }
                        }
                    }
                }
            }
        }
        try verifyOpeningOrigins()
        try verifyNotchEdgeAlignment()
        for header: CGFloat in [23, 33, 37.5] {
            for scale: CGFloat in [1, 2] {
                for notch: CGFloat in [0, 185] {
                    let metrics = PanelAttachmentMetrics(headerHeight: header, notchWidth: notch, pixelOverlap: 1 / scale)
                    for progress in [0.0, 0.01, 0.5, 1.0] {
                        let shape = LiquidPanelGeometry.shape(progress: progress,
                            panelRect: CGRect(x: 0, y: 0, width: 616, height: 430 + header),
                            originWidth: 185, attachment: metrics, attachmentBlend: 0)
                        let expectedTop = notch > 0
                            ? header + (metrics.preservedNeckTop - header) * LiquidPanelGeometry.smoothstep(0, 0.4, progress)
                            : 0
                        try check(shape.path.boundingBoxOfPath.minY == expectedTop, "preserve_draw_top")
                        try check(!shape.path.contains(CGPoint(x: 308, y: expectedTop - 0.001)),
                                  "preserve_fractional_band_empty")
                    }
                }
            }
        }
        for hz in [60.0, 120.0] {
            for reversal in [0.03, 0.08, 0.15] {
                var spring = LiquidSpring(value: 0, target: 1)
                for _ in 0..<Int(reversal * hz) { spring.step(seconds: 1 / hz, response: PanelAnimationTiming.openResponse) }
                let value = spring.value, velocity = spring.velocity
                spring.target = 0
                try check(spring.value == value && spring.velocity == velocity, "reversal_continuity")
                for _ in 0..<120 { spring.step(seconds: 1 / hz, response: PanelAnimationTiming.closeResponse) }
                try check(spring.isSettled(), "reversal_settles")
            }
        }
        var lowRate = LiquidSpring(value: 0, target: 1)
        var highRate = lowRate
        for _ in 0..<12 { lowRate.step(seconds: 1 / 60, response: PanelAnimationTiming.openResponse) }
        for _ in 0..<24 { highRate.step(seconds: 1 / 120, response: PanelAnimationTiming.openResponse) }
        try check(abs(lowRate.value - highRate.value) < 1e-12, "refresh_rate_equivalence")
        print("liquid_geometry=ok sizes=4 voice_heights=3 header_heights=2 notch_widths=3 attachment_blends=6 origins=4 samples=101 refresh_rates=60,120")
    }

    private static func verifyNotchEdgeAlignment() throws {
        for scale: CGFloat in [1, 2, 3] {
            for notch: CGFloat in [185, 246] {
                let pixel = 1 / scale
                let metrics = PanelAttachmentMetrics(headerHeight: 32, notchWidth: notch, pixelOverlap: pixel)
                let frame = CGRect(x: 19, y: 27, width: 616, height: 462)
                let shape = LiquidPanelGeometry.shape(progress: 1, panelRect: frame,
                    originWidth: notch, attachment: metrics, attachmentBlend: 0)
                let hardwareLeft = frame.midX - notch / 2
                let hardwareRight = frame.midX + notch / 2
                let sampleY = shape.neckRect.minY + pixel / 2
                // The hardware covers the upper anchor; drawn pixels must not protrude at either edge.
                guard shape.path.contains(CGPoint(x: shape.neckRect.minX + pixel / 2, y: sampleY)),
                      shape.path.contains(CGPoint(x: shape.neckRect.maxX - pixel / 2, y: sampleY)),
                      !shape.path.contains(CGPoint(x: hardwareLeft, y: sampleY)),
                      !shape.path.contains(CGPoint(x: hardwareRight, y: sampleY)),
                      abs(shape.neckRect.minX - hardwareLeft - 1) < 1e-9,
                      abs(hardwareRight - shape.neckRect.maxX - 1) < 1e-9 else {
                    throw PanelSoakVerificationError.failed("liquid_notch_edge_alignment scale=\(scale) notch=\(notch)")
                }
                // Sample the rounded hardware corner above the old 6pt join.
                // A straight-edge check alone misses the exposed wedge in this band.
                for header: CGFloat in [24, 32, 38] {
                    let roundedMetrics = PanelAttachmentMetrics(headerHeight: header, notchWidth: notch, pixelOverlap: pixel)
                    let rounded = LiquidPanelGeometry.shape(progress: 1, panelRect: frame,
                        originWidth: notch, attachment: roundedMetrics, attachmentBlend: 0)
                    for side in [rounded.neckRect.minX + pixel / 2, rounded.neckRect.maxX - pixel / 2] {
                        guard rounded.path.contains(CGPoint(x: side, y: frame.minY + header - 8)) else {
                            throw PanelSoakVerificationError.failed("liquid_rounded_notch_corner_gap scale=\(scale) header=\(header)")
                        }
                    }
                    for side in [hardwareLeft, hardwareRight] {
                        guard rounded.path.contains(CGPoint(x: side, y: frame.minY + header - 4)) else {
                            throw PanelSoakVerificationError.failed("liquid_inset_notch_join_gap scale=\(scale) header=\(header)")
                        }
                    }
                }
            }
        }
        print("liquid_notch_edge_alignment=ok scales=1,2,3 notch_widths=185,246 sides=left,right inset_points=1 rounded_corners=connected upper_protrusion=absent")
    }

    private static func verifyOpeningOrigins() throws {
        func check(_ condition: Bool, _ code: String) throws {
            guard condition else { throw PanelSoakVerificationError.failed("liquid_origin_" + code) }
        }
        for size in PanelSizeOption.allCases {
            let body = PanelLayout.previewSize(for: size)
            for header: CGFloat in [24, 32, 38] {
                for notch: CGFloat in [185, 246] {
                    let metrics = PanelAttachmentMetrics(headerHeight: header, notchWidth: notch)
                    let frame = CGRect(x: 0, y: 0, width: body.width + 16, height: body.height + header)
                    let open = LiquidPanelGeometry.shape(progress: 1, panelRect: frame,
                        originWidth: notch, attachment: metrics, attachmentBlend: 0)
                    for step in 0...100 {
                        let progress = Double(step) / 100
                        let preserve = LiquidPanelGeometry.shape(progress: progress, panelRect: frame,
                            originWidth: notch, attachment: metrics, attachmentBlend: 0)
                        try check(preserve.neckRect.width == open.neckRect.width && preserve.upperRadius == 0
                                  && preserve.fillOpacity == 1, "preserve_fixed_anchor")
                        let path = preserve.path
                        try check(path.boundingBoxOfPath.minY >= metrics.preservedNeckTop
                                  && preserve.strokePath.boundingBoxOfPath.minY >= header, "preserve_compact_join_bounds")
                        for y in stride(from: CGFloat(0.125), to: metrics.preservedNeckTop, by: 0.25) {
                            for x in [CGFloat(0.125), open.neckRect.minX, frame.midX, open.neckRect.maxX, frame.maxX - 0.125] {
                                try check(!path.contains(CGPoint(x: x, y: y)), "preserve_above_join_empty")
                            }
                        }
                        if progress == 0 {
                            try check(path.boundingBoxOfPath.height == 0 && preserve.joinRadius == 0,
                                      "preserve_closed_no_tab")
                        } else {
                            try check(preserve.joinRadius > 0
                                      && abs(preserve.neckRect.height - preserve.joinRadius) < 1e-9,
                                      "preserve_curved_join_without_vertical_tab")
                            try check(path.contains(CGPoint(x: frame.midX, y: preserve.neckRect.midY)),
                                      "preserve_meniscus_connected")
                            let joinMid = CGPoint(x: preserve.neckRect.maxX + preserve.joinRadius * 0.5,
                                                  y: header - preserve.joinRadius * 0.1)
                            try check(path.contains(joinMid), "preserve_visible_concave_join")
                            try check(!path.contains(CGPoint(x: preserve.neckRect.maxX + preserve.joinRadius * 0.5,
                                                             y: header - preserve.joinRadius * 0.5)),
                                      "preserve_join_is_curve_not_rectangle")
                            let stroke = preserve.strokePath.copy(strokingWithWidth: 1, lineCap: .butt,
                                lineJoin: .round, miterLimit: 2)
                            try check(!stroke.contains(CGPoint(x: frame.midX, y: header)), "preserve_no_connection_seam")
                        }
                        if preserve.rect.height > 2 {
                            try check(path.contains(CGPoint(x: frame.midX, y: header + 1)), "preserve_body_connected")
                        }
                        let cover = LiquidPanelGeometry.shape(progress: progress, panelRect: frame,
                            originWidth: notch, attachment: metrics, attachmentBlend: 1)
                        try check(cover.path.boundingBoxOfPath.minY == frame.minY && cover.contentOffset == 0, "cover_screen_edge")
                        let neckWidth = notch + metrics.pixelOverlap * 2
                        let horizontal = (cover.rect.width - neckWidth) / (body.width - neckWidth)
                        let vertical = (cover.rect.maxY - header) / body.height
                        try check(abs(horizontal - vertical) < 1e-9 && abs(horizontal - progress) < 1e-9,
                                  "cover_simultaneous_growth")
                    }
                }
            }
        }
        let noNotchMetrics = PanelAttachmentMetrics(headerHeight: 24, notchWidth: 0)
        let noNotchFrame = CGRect(x: 0, y: 0, width: 616, height: 454)
        let noVoice = LiquidPanelGeometry.shape(progress: 1, panelRect: noNotchFrame,
            originWidth: 168, attachment: noNotchMetrics, attachmentBlend: 0)
        let withVoice = LiquidPanelGeometry.shape(progress: 1, panelRect: noNotchFrame,
            originWidth: 108, attachment: noNotchMetrics, attachmentBlend: 0)
        try check(noVoice.neckRect == withVoice.neckRect, "no_notch_voice_keeps_header")
        try check(noVoice.neckRect.minY == 0 && noVoice.upperRadius == 0,
                  "no_notch_straight_to_screen_top")
        try check(noVoice.path.contains(CGPoint(x: noVoice.neckRect.minX + 0.5, y: 0.5))
                  && noVoice.path.contains(CGPoint(x: noVoice.neckRect.maxX - 0.5, y: 0.5)),
                  "no_notch_top_corners_are_square")
        print("liquid_opening_origins=ok preserve_above_join=empty preserve_closed_tabs=absent meniscus=connected,seamless cover_origin=notch horizontal_vertical_together=ok")
    }

    private static func verifyNativeJunction(evidenceDirectory: URL) async throws {
        guard CGPreflightScreenCaptureAccess() else {
            print("liquid_junction_fixture=skipped screen_capture_permission_unavailable")
            return
        }
        guard let screen = NSScreen.screens.first else {
            throw PanelSoakVerificationError.failed("liquid_junction_fixture_screen")
        }
        let metrics = PanelAttachmentMetrics(headerHeight: 32, notchWidth: 185,
                                             pixelOverlap: 1 / screen.backingScaleFactor)
        let frame = NSRect(x: screen.frame.midX - 308, y: screen.frame.maxY - 462,
                           width: 616, height: 462)
        let surface = LiquidPanelSurfaceView(hostingView: NSView(frame: .zero))
        let window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.animationBehavior = .none
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.ignoresMouseEvents = true
        window.contentView = surface
        window.setFrame(frame, display: true)
        surface.layoutContent(size: frame.size)
        let animator = LiquidPanelAnimator()
        animator.view = surface
        animator.originWidth = metrics.notchWidth
        animator.setAttachment(metrics, style: .preserveMenu, animated: false)
        animator.snap(progress: 0, frame: frame)
        defer { animator.snap(progress: 0, frame: frame); window.orderOut(nil); window.close() }
        func waitForAnimation() async throws {
            let deadline = Date().addingTimeInterval(2)
            while !animator.isIdle && Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard animator.isIdle else {
                throw PanelSoakVerificationError.failed("liquid_junction_fixture_animation_timeout")
            }
        }
        // Injected geometry exercises the product renderer without requiring a notched display.
        try await LiquidScreenEdgeVerification.run(screen: screen, frame: frame, attachment: metrics,
            style: .preserveMenu, evidenceDirectory: evidenceDirectory.appendingPathComponent("injected-notch"),
            open: { window.orderFrontRegardless(); animator.snap(progress: 0, frame: frame) },
            settle: {
                try await Task.sleep(for: .milliseconds(60))
                animator.setReveal(1)
                try await waitForAnimation()
            },
            close: { animator.setReveal(0); try await waitForAnimation(); window.orderOut(nil) })
        print("liquid_junction_fixture=ok injected_notch=true notch_width=185 header_height=32 physical_notch_acceptance=false")
    }

    static func run(evidenceDirectory: URL) async throws {
        try verifyGeometry()
        NSApp.setActivationPolicy(.accessory)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        try await LiquidCompositionVerification.run(evidenceDirectory: evidenceDirectory)
        try await verifyNativeJunction(evidenceDirectory: evidenceDirectory)
        let registry = ProviderRegistry(providers: [TimerProvider(), CalculatorProvider()])
        let controller = HoverWindowController(settingsDefaults: EphemeralAppSettingsDefaults(), providerRegistry: registry)
        try await controller.runLiquidMotionVerification(evidenceDirectory: evidenceDirectory)
        let soak = try await controller.runNonPhysicalSoakVerification(iterations: 100, providerIDs: [TimerProvider.pluginID, CalculatorProvider.pluginID])
        print("liquid_soak=ok iterations=\(soak.iterations) animated_cycles=\(soak.animatedTransitionCycles) windows=\(soak.baselineWindowCount)->\(soak.finalWindowCount) threads=\(soak.baselineThreadCount)->\(soak.finalThreadCount) peak_threads=\(soak.maximumThreadCount)")
        print("liquid_motion_verify=ok")
        if CommandLine.arguments.contains("--show-preview") {
            if CommandLine.arguments.contains("--preview-cover-menu") { controller.appSettings.panelAttachmentStyle = .coverMenu }
            controller.openPanel(showing: CalculatorProvider.pluginID)
            if CommandLine.arguments.contains("--show-motion-settings") { controller.openSettingsFromMenu() }
            FileHandle.standardOutput.write(Data("liquid_preview=ready temporary_settings=true providers=timer,calculator\n".utf8))
            try await Task.sleep(for: .seconds(60))
        }
    }
}

@MainActor
private enum LiquidCompositionVerification {
    static func run(evidenceDirectory: URL) async throws {
        let canCapture = CGPreflightScreenCaptureAccess()
        for style in PanelAttachmentStyle.allCases {
            let frame = NSRect(x: 200, y: 200, width: 600, height: 430)
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let web = WKWebView(frame: NSRect(origin: .zero, size: frame.size), configuration: configuration)
            web.loadHTMLString("<html><body style='margin:0;background:#d030e0;width:100vw;height:100vh'></body></html>", baseURL: nil)
            let surface = LiquidPanelSurfaceView(hostingView: web)
            let window = NSPanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.level = .floating
            window.sharingType = .readOnly
            window.contentView = surface
            window.setFrame(frame, display: true)
            surface.layoutContent(size: frame.size)
            window.orderFrontRegardless()
            defer { window.orderOut(nil); window.close(); web.stopLoading(); web.loadHTMLString("", baseURL: nil) }
            try await Task.sleep(for: .milliseconds(600))
            let loadDeadline = Date().addingTimeInterval(5)
            while web.isLoading && Date() < loadDeadline { try await Task.sleep(for: .milliseconds(20)) }
            let fixtureColor = try await web.evaluateJavaScript("getComputedStyle(document.body).backgroundColor") as? String
            guard !web.isLoading, fixtureColor == "rgb(208, 48, 224)" else {
                throw PanelSoakVerificationError.failed("liquid_composition_fixture_not_loaded")
            }
            surface.apply(progress: 0.7, screenRect: frame, contentRect: frame, originWidth: 185,
                          attachment: PanelAttachmentMetrics(headerHeight: 33, notchWidth: 185), attachmentBlend: style.blend)
            try await Task.sleep(for: .milliseconds(100))
            let invisiblePoint = NSPoint(x: frame.width / 2, y: frame.height - 1)
            guard surface.hitTest(surface.convert(invisiblePoint, to: surface.superview)) == nil else {
                throw PanelSoakVerificationError.failed("liquid_composition_outside_hit")
            }
            surface.apply(progress: 1, screenRect: frame, contentRect: frame, originWidth: 185,
                          attachment: PanelAttachmentMetrics(headerHeight: 33, notchWidth: 185), attachmentBlend: style.blend)
            guard let hit = surface.hitTest(surface.convert(NSPoint(x: 300, y: 200), to: surface.superview)), hit !== surface else {
                throw PanelSoakVerificationError.failed("liquid_composition_visible_hit")
            }
            let metrics = PanelAttachmentMetrics(headerHeight: 33, notchWidth: 185)
            surface.apply(progress: 0.05, screenRect: frame, contentRect: frame, originWidth: 185,
                          attachment: metrics, attachmentBlend: style.blend)
            let hiddenPoint = NSPoint(x: 300, y: surface.currentShape.rect.midY)
            guard surface.hitTest(surface.convert(hiddenPoint, to: surface.superview)) === surface else {
                throw PanelSoakVerificationError.failed("liquid_composition_hidden_hit")
            }
            surface.apply(progress: 1, screenRect: frame, contentRect: frame, originWidth: 185,
                          attachment: metrics, attachmentBlend: style.blend)
            let menuPoint = NSPoint(x: 20, y: 16)
            let menuHit = surface.hitTest(surface.convert(menuPoint, to: surface.superview))
            guard (menuHit == nil) == (style == .preserveMenu) else {
                throw PanelSoakVerificationError.failed("liquid_composition_menu_hit")
            }
            if style == .preserveMenu {
                let shape = surface.currentShape
                for point in [NSPoint(x: 300, y: 1), NSPoint(x: 300, y: metrics.preservedNeckTop - 1),
                              NSPoint(x: 20, y: 16),
                              NSPoint(x: shape.neckRect.minX - shape.joinRadius - 1, y: 32),
                              NSPoint(x: shape.neckRect.maxX + shape.joinRadius + 1, y: 32)] {
                    guard surface.hitTest(surface.convert(point, to: surface.superview)) == nil else {
                        throw PanelSoakVerificationError.failed("liquid_composition_above_join_hit")
                    }
                }
                let joinPoint = NSPoint(x: surface.currentShape.neckRect.maxX + surface.currentShape.joinRadius * 0.5,
                                        y: metrics.headerHeight - surface.currentShape.joinRadius * 0.1)
                guard surface.hitTest(surface.convert(joinPoint, to: surface.superview)) != nil else {
                    throw PanelSoakVerificationError.failed("liquid_composition_meniscus_hit")
                }
            }
            print("liquid_composition=ok style=\(style.rawValue) webview_hit_tests=visible,hidden,menu")
            guard canCapture else {
                print("liquid_composition_pixels=skipped style=\(style.rawValue) screen_capture_permission_unavailable")
                continue
            }
            surface.apply(progress: 0.7, screenRect: frame, contentRect: frame, originWidth: 185,
                          attachment: metrics, attachmentBlend: style.blend)
            try await Task.sleep(for: .milliseconds(100))
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let item = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                let own = content.windows.filter { $0.owningApplication?.processID == getpid() }.map { $0.windowID }
                throw PanelSoakVerificationError.failed("liquid_composition_window_unavailable own=\(own) expected=\(window.windowNumber) visible=\(window.isVisible)")
            }
            let capture = SCStreamConfiguration()
            capture.width = 600; capture.height = 430
            capture.showsCursor = false; capture.capturesAudio = false
            capture.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: item), configuration: capture)
            let rep = NSBitmapImageRep(cgImage: image)
            guard let data = rep.representation(using: .png, properties: [:]) else {
                throw PanelSoakVerificationError.failed("liquid_composition_image")
            }
            try data.write(to: evidenceDirectory.appendingPathComponent("webview-\(style.rawValue)-p070.png"))
            let shape = surface.currentShape
            let edge = shape.path.copy(strokingWithWidth: 2, lineCap: .round, lineJoin: .round, miterLimit: 2)
            var visibleWebPixels = 0, leakingWebPixels = 0
            var leakMinX = rep.pixelsWide, leakMinY = rep.pixelsHigh, leakMaxX = 0, leakMaxY = 0
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    // Detect the magenta fixture by contrast, independent of the capture's display profile.
                    if color.alphaComponent > 0.2 && color.redComponent > 0.3 && color.blueComponent > 0.3
                        && min(color.redComponent, color.blueComponent) - color.greenComponent > 0.1 {
                        visibleWebPixels += 1
                        let point = CGPoint(x: (Double(x) + 0.5) * 600 / Double(rep.pixelsWide), y: (Double(y) + 0.5) * 430 / Double(rep.pixelsHigh))
                        if !shape.path.contains(point) && !edge.contains(point) {
                            leakingWebPixels += 1
                            leakMinX = min(leakMinX, x); leakMaxX = max(leakMaxX, x)
                            leakMinY = min(leakMinY, y); leakMaxY = max(leakMaxY, y)
                        }
                    }
                }
            }
            guard visibleWebPixels > 1000, leakingWebPixels == 0 else {
                throw PanelSoakVerificationError.failed("liquid_composition_mask pixels=\(visibleWebPixels) leaking=\(leakingWebPixels) bounds=\(leakMinX),\(leakMinY)-\(leakMaxX),\(leakMaxY) image=\(rep.pixelsWide)x\(rep.pixelsHigh) shape=\(shape.rect)")
            }
            print("liquid_composition_pixels=ok style=\(style.rawValue) webview_pixels=\(visibleWebPixels) outside_pixels=0")
        }
    }
}
