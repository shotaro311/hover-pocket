import Darwin
import AppKit
import Foundation
import WebKit

enum CodexAppServerRealtimeVerificationError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let code):
            VoiceTextSafety.sanitizeErrorCode(code)
        }
    }
}

struct CodexAppServerRealtimeVerificationResult: Sendable {
    let voiceCount: Int
    let processClosed: Bool
}

private protocol CodexAppServerRealtimeVerificationSafeError {
    var safeErrorCode: String { get }
}

@MainActor
enum CodexAppServerRealtimeVerificationCommand {
    private static let workspacePrefix = "HoverPocketCodexRealtime-"

    static func run() async throws -> CodexAppServerRealtimeVerificationResult {
        let toolAdapter = CodexAppServerRealtimeVerificationToolAdapter()
        let compatibility = await CodexAppServerCompatibilityProbe.shared.probe(
            dynamicTools: toolAdapter.dynamicTools
        )
        guard compatibility.gate.isReady else {
            throw CodexAppServerRealtimeVerificationError.failed(
                compatibility.gate.safeErrorCode ?? "codex_app_server_not_ready"
            )
        }
        guard await CodexAppServerCompatibilityProbe.shared.isCurrent(compatibility),
              let executableURL = compatibility.executableURL,
              let profile = compatibility.appServerProfile else {
            throw CodexAppServerRealtimeVerificationError.failed(
                "codex_app_server_identity_changed"
            )
        }

        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
            workspacePrefix + UUID().uuidString.lowercased(),
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: workspace,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw CodexAppServerRealtimeVerificationError.failed(
                "realtime_verifier_workspace_failed"
            )
        }

        let processTracker = CodexAppServerRealtimeVerificationProcessTracker()
        let coordinator = CodexVoiceCoordinator(
            featureEnabled: true,
            workspaceDirectory: workspace,
            restartDelaysNanoseconds: [],
            sdpTimeoutNanoseconds: 30_000_000_000,
            clientFactory: {
                let client = try await CodexAppServerClient.start(
                    options: CodexAppServerClientOptions(
                        executableURL: executableURL,
                        launchArguments: CodexVoiceAppServerLaunchPolicy.arguments,
                        processEnvironment: profile.processEnvironment,
                        workingDirectoryURL: profile.codexHomeURL,
                        requestTimeout: 30,
                        clientTitle: "HoverPocket Realtime Verifier",
                        clientVersion: Bundle.main.object(
                            forInfoDictionaryKey: "CFBundleShortVersionString"
                        ) as? String ?? "0.0.0",
                        experimentalAPI: true,
                        processStarted: { processID in
                            processTracker.record(processID)
                        }
                    )
                )
                return client
            },
            toolAdapter: toolAdapter,
            rootThreadEphemeral: true
        )
        let webRTC = CodexRealtimeSDPConnectionProbe()
        var processID: Int32?

        do {
            await coordinator.initialize()
            let initialized = coordinator.snapshot
            guard initialized.availability == .ready,
                  initialized.voiceCount > 0,
                  let initializedProcessID = initialized.appServerProcessID else {
                throw CodexAppServerRealtimeVerificationError.failed(
                    initialized.lastErrorCode ?? "realtime_account_initialization_failed"
                )
            }
            let trackedProcessID = processTracker.current()
            guard trackedProcessID == initializedProcessID else {
                throw CodexAppServerRealtimeVerificationError.failed(
                    "realtime_app_server_process_identity_mismatch"
                )
            }
            processID = initializedProcessID

            try await webRTC.load()
            let offer = try await webRTC.createOffer()
            let answer: CodexVoiceWebRTCAnswer
            do {
                answer = try await coordinator.startWebRTC(sdpOffer: offer)
            } catch {
                throw CodexAppServerRealtimeVerificationError.failed(
                    coordinator.snapshot.lastErrorCode ?? "realtime_start_failed"
                )
            }
            guard VoiceTextSafety.sanitizeIdentifier(answer.rootThreadID)
                    == answer.rootThreadID,
                  !answer.rootThreadID.isEmpty,
                  answer.sdp.hasPrefix("v=0"),
                  answer.sdp.utf8.count <= 131_072 else {
                throw CodexAppServerRealtimeVerificationError.failed(
                    "realtime_answer_invalid"
                )
            }

            try await webRTC.acceptAnswer(answer.sdp)
            coordinator.markTransportAttached()
            let connected = coordinator.snapshot
            guard connected.sessionStatus == .connected,
                  connected.transportAttached,
                  connected.rootThreadID == answer.rootThreadID,
                  toolAdapter.executionCount == 0 else {
                throw CodexAppServerRealtimeVerificationError.failed(
                    "realtime_connection_readback_failed"
                )
            }

            await webRTC.close()
            await coordinator.stopRealtime()
            await coordinator.close()
            let processClosed = await waitForProcessExit(initializedProcessID)
            guard processClosed else {
                throw CodexAppServerRealtimeVerificationError.failed(
                    "realtime_app_server_process_leaked"
                )
            }
            guard removeWorkspace(workspace) else {
                throw CodexAppServerRealtimeVerificationError.failed(
                    "realtime_verifier_workspace_leaked"
                )
            }
            return CodexAppServerRealtimeVerificationResult(
                voiceCount: initialized.voiceCount,
                processClosed: true
            )
        } catch {
            await webRTC.close()
            await coordinator.stopRealtime()
            await coordinator.close()
            var processClosed = true
            let trackedProcessID = processTracker.current()
            let failedProcessID = processID ?? trackedProcessID
            if let failedProcessID {
                processClosed = await waitForProcessExit(failedProcessID)
            }
            let workspaceClosed = removeWorkspace(workspace)
            guard processClosed else {
                throw CodexAppServerRealtimeVerificationError.failed(
                    "realtime_app_server_process_leaked"
                )
            }
            guard workspaceClosed else {
                throw CodexAppServerRealtimeVerificationError.failed(
                    "realtime_verifier_workspace_leaked"
                )
            }
            if let safeError = error as? CodexAppServerRealtimeVerificationError {
                throw safeError
            }
            if let safeError = error as? CodexAppServerRealtimeVerificationSafeError {
                throw CodexAppServerRealtimeVerificationError.failed(
                    safeError.safeErrorCode
                )
            }
            throw CodexAppServerRealtimeVerificationError.failed(
                "codex_app_server_realtime_verification_failed"
            )
        }
    }

    private static func waitForProcessExit(_ processID: Int32) async -> Bool {
        for _ in 0..<40 {
            if Darwin.kill(processID, 0) != 0, Darwin.errno == ESRCH {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return Darwin.kill(processID, 0) != 0 && Darwin.errno == ESRCH
    }

    private static func removeWorkspace(_ workspace: URL) -> Bool {
        try? FileManager.default.removeItem(at: workspace)
        return !FileManager.default.fileExists(atPath: workspace.path)
    }
}

private final class CodexAppServerRealtimeVerificationProcessTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var processID: Int32?

    func record(_ processID: Int32) {
        lock.lock()
        defer { lock.unlock() }
        self.processID = processID
    }

    func current() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        return processID
    }
}

@MainActor
private final class CodexAppServerRealtimeVerificationToolAdapter:
    CodexVoiceCapabilityToolAdapterProtocol {
    private(set) var executionCount = 0

    var dynamicTools: [CodexJSONValue] {
        [
            .object([
                "type": .string("function"),
                "name": .string("hoverpocket_realtime_probe_read"),
                "description": .string("Verify the HoverPocket delegated tool route."),
                "inputSchema": .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                    "additionalProperties": .bool(false)
                ]),
                "deferLoading": .bool(false)
            ])
        ]
    }

    func handle(
        request: CodexAppServerRequest,
        context: CodexVoiceToolRequestContext
    ) async -> CodexAppServerReply {
        _ = request
        _ = context
        executionCount += 1
        return .success(.object([
            "success": .bool(false),
            "contentItems": .array([
                .object([
                    "type": .string("inputText"),
                    "text": .string("{\"code\":\"verification_tool_not_expected\",\"status\":\"failed\"}")
                ])
            ])
        ]))
    }

    func cancelSession(_ sessionID: String) {
        _ = sessionID
    }
}

@MainActor
private final class CodexRealtimeSDPConnectionProbe: NSObject, WKNavigationDelegate {
    private enum ProbeError: Error, CodexAppServerRealtimeVerificationSafeError {
        case pageUnavailable
        case offerUnavailable
        case connectionUnavailable

        var safeErrorCode: String {
            switch self {
            case .pageUnavailable:
                "realtime_probe_page_unavailable"
            case .offerUnavailable:
                "realtime_probe_offer_unavailable"
            case .connectionUnavailable:
                "realtime_probe_connection_unavailable"
            }
        }
    }

    private static let scheme = "hoverpocket-realtime-verifier"
    private static let host = "local"
    private static let pageURL = URL(string: "\(scheme)://\(host)/index.html")!
    private let webView: WKWebView
    private let hostWindow: NSWindow
    private let schemeHandler: CodexRealtimeProbeSchemeHandler
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var loadTimeoutTask: Task<Void, Never>?
    private var loaded = false

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsAirPlayForMediaPlayback = false
        schemeHandler = CodexRealtimeProbeSchemeHandler(
            pageURL: Self.pageURL,
            page: Self.page
        )
        configuration.setURLSchemeHandler(
            schemeHandler,
            forURLScheme: Self.scheme
        )
        webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 1, height: 1),
            configuration: configuration
        )
        hostWindow = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()
        webView.navigationDelegate = self
        hostWindow.isReleasedWhenClosed = false
        hostWindow.isOpaque = false
        hostWindow.alphaValue = 0.01
        hostWindow.ignoresMouseEvents = true
        hostWindow.contentView = webView
        hostWindow.orderBack(nil)
    }

    func load() async throws {
        if loaded { return }
        try await withCheckedThrowingContinuation { continuation in
            loadContinuation = continuation
            loadTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                self?.finishLoad(.failure(ProbeError.pageUnavailable))
            }
            webView.load(URLRequest(url: Self.pageURL))
        }
    }

    func createOffer() async throws -> String {
        let value: Any?
        do {
            value = try await webView.callAsyncJavaScript(
                Self.createOfferScript,
                arguments: [:],
                in: nil,
                contentWorld: .page
            )
        } catch {
            throw ProbeError.offerUnavailable
        }
        guard let offer = value as? String,
              offer.hasPrefix("v=0"),
              offer.utf8.count <= 131_072 else {
            throw ProbeError.offerUnavailable
        }
        return offer
    }

    func acceptAnswer(_ answer: String) async throws {
        let value: Any?
        do {
            value = try await webView.callAsyncJavaScript(
                Self.acceptAnswerScript,
                arguments: ["answer": answer],
                in: nil,
                contentWorld: .page
            )
        } catch {
            throw ProbeError.connectionUnavailable
        }
        guard value as? String == "connected" else {
            throw ProbeError.connectionUnavailable
        }
    }

    func close() async {
        let closeGate = CodexRealtimeProbeCloseGate()
        let cleanupTask = Task { @MainActor [weak webView] in
            if let webView {
                _ = try? await webView.callAsyncJavaScript(
                    Self.closeScript,
                    arguments: [:],
                    in: nil,
                    contentWorld: .page
                )
            }
            await closeGate.finish()
        }
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await closeGate.finish()
        }
        await closeGate.wait()
        cleanupTask.cancel()
        timeoutTask.cancel()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
        hostWindow.orderOut(nil)
        hostWindow.contentView = nil
        finishLoad(.failure(ProbeError.pageUnavailable))
    }

    private func finishLoad(_ result: Result<Void, Error>) {
        guard let continuation = loadContinuation else { return }
        loadContinuation = nil
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
        if case .success = result {
            loaded = true
        }
        continuation.resume(with: result)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url
        let allowed = url == nil || url == Self.pageURL || url?.absoluteString == "about:blank"
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoad(.success(()))
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        _ = error
        finishLoad(.failure(ProbeError.pageUnavailable))
    }

    private static let page = #"""
    <!doctype html>
    <html><head><meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; connect-src 'none'; media-src 'none'; img-src 'none'; style-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; webrtc 'allow'">
    </head><body></body></html>
    """#

    private static let createOfferScript = #"""
    if (window.hoverPocketRealtimeProbe) throw new Error("probe_active");
    const peer = new RTCPeerConnection({iceServers: []});
    const channel = peer.createDataChannel("oai-events");
    const state = {peer, channel, audioContext: null, oscillator: null, silentTrack: null};
    window.hoverPocketRealtimeProbe = state;
    try {
      const AudioContextConstructor = window.AudioContext || window.webkitAudioContext;
      if (!AudioContextConstructor) throw new Error("audio_context_unavailable");
      state.audioContext = new AudioContextConstructor();
      state.oscillator = state.audioContext.createOscillator();
      const gain = state.audioContext.createGain();
      const destination = state.audioContext.createMediaStreamDestination();
      gain.gain.value = 0;
      state.oscillator.connect(gain);
      gain.connect(destination);
      state.oscillator.start();
      state.silentTrack = destination.stream.getAudioTracks()[0];
      if (!state.silentTrack) throw new Error("silent_track_unavailable");
      peer.addTrack(state.silentTrack, destination.stream);
      const offer = await peer.createOffer({offerToReceiveAudio: true});
      await peer.setLocalDescription(offer);
      await new Promise((resolve) => {
        if (peer.iceGatheringState === "complete") return resolve();
        let settled = false;
        const finish = () => {
          if (settled) return;
          settled = true;
          clearTimeout(earlyTimeout);
          clearTimeout(finalTimeout);
          peer.removeEventListener("icegatheringstatechange", onChange);
          resolve();
        };
        const earlyTimeout = setTimeout(() => {
          if (peer.localDescription?.sdp?.includes("a=candidate:")) finish();
        }, 3000);
        const finalTimeout = setTimeout(finish, 8000);
        const onChange = () => {
          if (peer.iceGatheringState !== "complete") return;
          finish();
        };
        peer.addEventListener("icegatheringstatechange", onChange);
      });
      if (!peer.localDescription || typeof peer.localDescription.sdp !== "string") {
        throw new Error("offer_missing");
      }
      return peer.localDescription.sdp;
    } catch (error) {
      try { channel.close(); } catch (_) {}
      try { peer.close(); } catch (_) {}
      try { state.silentTrack?.stop(); } catch (_) {}
      try { state.oscillator?.stop(); } catch (_) {}
      try { await state.audioContext?.close(); } catch (_) {}
      delete window.hoverPocketRealtimeProbe;
      throw error;
    }
    """#

    private static let acceptAnswerScript = #"""
    const state = window.hoverPocketRealtimeProbe;
    if (!state || typeof answer !== "string") throw new Error("answer_invalid");
    await state.peer.setRemoteDescription({type: "answer", sdp: answer});
    return await new Promise((resolve, reject) => {
      let settled = false;
      const cleanup = () => {
        state.peer.removeEventListener("connectionstatechange", check);
        state.channel.removeEventListener("open", check);
      };
      const finish = (value, error) => {
        if (settled) return;
        settled = true;
        clearTimeout(timeout);
        cleanup();
        error ? reject(new Error(error)) : resolve(value);
      };
      const check = () => {
        if (["failed", "disconnected", "closed"].includes(state.peer.connectionState)) {
          return finish(null, "connection_failed");
        }
        if (state.peer.connectionState === "connected" && state.channel.readyState === "open") {
          finish("connected", null);
        }
      };
      const timeout = setTimeout(() => finish(null, "connection_timeout"), 20000);
      state.peer.addEventListener("connectionstatechange", check);
      state.channel.addEventListener("open", check);
      check();
    });
    """#

    private static let closeScript = #"""
    const state = window.hoverPocketRealtimeProbe;
    if (state) {
      try { state.channel.close(); } catch (_) {}
      try { state.peer.close(); } catch (_) {}
      try { state.silentTrack.stop(); } catch (_) {}
      try { state.oscillator.stop(); } catch (_) {}
      try { await state.audioContext.close(); } catch (_) {}
      delete window.hoverPocketRealtimeProbe;
    }
    return true;
    """#
}

private final class CodexRealtimeProbeSchemeHandler: NSObject, WKURLSchemeHandler {
    private let pageURL: URL
    private let data: Data

    init(pageURL: URL, page: String) {
        self.pageURL = pageURL
        data = Data(page.utf8)
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard urlSchemeTask.request.url == pageURL else {
            urlSchemeTask.didFailWithError(
                CodexAppServerRealtimeVerificationError.failed(
                    "realtime_probe_page_unavailable"
                )
            )
            return
        }
        let response = URLResponse(
            url: pageURL,
            mimeType: "text/html",
            expectedContentLength: data.count,
            textEncodingName: "utf-8"
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

private actor CodexRealtimeProbeCloseGate {
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !finished else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}
