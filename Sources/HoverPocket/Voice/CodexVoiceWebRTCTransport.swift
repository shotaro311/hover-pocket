import AVFoundation
import SwiftUI
import WebKit

@MainActor
final class CodexVoiceWebRTCDriver: ObservableObject {
    @Published private(set) var isReady = false

    private weak var runtimeHost: CodexVoiceRuntimeHost?
    private weak var webView: WKWebView?
    private var pageReady = false
    private var sessionStarting = false
    private var transportGeneration: UInt64 = 0
    private var activeOperationID: String?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var startTimeoutTask: Task<Void, Never>?
    private let startTimeoutNanoseconds: UInt64

    init(
        runtimeHost: CodexVoiceRuntimeHost,
        startTimeoutNanoseconds: UInt64 = 30_000_000_000
    ) {
        self.runtimeHost = runtimeHost
        self.startTimeoutNanoseconds = startTimeoutNanoseconds
    }

    func attach(webView: WKWebView) {
        self.webView = webView
        pageReady = false
        isReady = false
    }

    func detach(webView: WKWebView) {
        guard self.webView === webView else { return }
        closeTransport(
            event: "webview_detached",
            clearTransientUIState: true
        )
        self.webView = nil
        pageReady = false
        isReady = false
    }

    func startSession() async throws {
        if !pageReady {
            for _ in 0..<20 where !pageReady {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        guard pageReady,
              !sessionStarting,
              let runtimeHost,
              runtimeHost.beginMicrophoneRequest() else {
            runtimeHost?.markSessionFailure("microphone_request_not_armed")
            throw CodexVoiceWebRTCTransportError.microphoneRequestNotArmed
        }
        transportGeneration &+= 1
        let generation = transportGeneration
        sessionStarting = true
        _ = MacOSVoiceE2EReceiptStore.shared?.beginMediaSession()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startContinuation = continuation
                startTimeoutTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try await Task.sleep(nanoseconds: self.startTimeoutNanoseconds)
                    } catch {
                        return
                    }
                    guard self.sessionStarting,
                          self.transportGeneration == generation else { return }
                    self.closeTransport(
                        event: "transport_start_timed_out",
                        errorCode: "webrtc_start_timed_out"
                    )
                }
                switch CodexVoiceSystemMicrophoneAuthorizationPolicy.decision(
                    for: AVCaptureDevice.authorizationStatus(for: .audio)
                ) {
                case .proceed:
                    continueAfterSystemAuthorization(granted: true, generation: generation)
                case .request:
                    AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                        Task { @MainActor [weak self] in
                            self?.continueAfterSystemAuthorization(
                                granted: granted,
                                generation: generation
                            )
                        }
                    }
                case .deny:
                    continueAfterSystemAuthorization(granted: false, generation: generation)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self,
                      self.sessionStarting,
                      self.transportGeneration == generation else { return }
                self.closeTransport(event: "transport_start_cancelled")
            }
        }
    }

    private func continueAfterSystemAuthorization(granted: Bool, generation: UInt64) {
        guard sessionStarting,
              transportGeneration == generation else { return }
        guard granted else {
            sessionStarting = false
            runtimeHost?.markSessionFailure("microphone_permission_denied")
            resolveStart(.failure(CodexVoiceWebRTCTransportError.microphonePermissionDenied))
            return
        }
        guard let runtimeHost,
              runtimeHost.beginMicrophoneRequest() else {
            sessionStarting = false
            runtimeHost?.markSessionFailure("microphone_request_not_armed")
            resolveStart(.failure(CodexVoiceWebRTCTransportError.microphoneRequestNotArmed))
            return
        }

        let operationID = String(generation)
        activeOperationID = operationID
        callAsync(
            "return await window.hoverPocketVoice.start(operationId);",
            arguments: ["operationId": operationID]
        ) { [weak self] error in
            guard let self,
                  self.activeOperationID == operationID,
                  error != nil else { return }
            self.closeTransport(
                event: "transport_start_failed",
                errorCode: "webrtc_start_failed"
            )
        }
    }

    func setMuted(_ muted: Bool) {
        evaluate("window.hoverPocketVoice.setMuted(\(muted ? "true" : "false"))")
        runtimeHost?.setMuted(muted)
    }

    func stopSession() async {
        closeTransport(event: "session_stopped", requestRealtimeStop: false)
        await runtimeHost?.stopRealtime()
    }

    func detachForPanelClose() {
        closeTransport(
            event: "panel_detached",
            clearTransientUIState: true
        )
    }

    func prepareForApplicationTermination() {
        closeTransport(
            event: "application_terminated",
            clearTransientUIState: true
        )
    }

    func handleMessage(_ body: Any) {
        guard let object = body as? [String: Any],
              let type = object["type"] as? String else {
            closeTransport(
                event: "transport_message_invalid",
                errorCode: "webrtc_message_invalid"
            )
            return
        }

        switch type {
        case "ready":
            pageReady = true
            isReady = true
        case "offer":
            guard let operationID = object["operationId"] as? String,
                  operationID == activeOperationID,
                  sessionStarting else { return }
            guard let sdp = object["sdp"] as? String,
                  !sdp.isEmpty,
                  sdp.utf8.count <= 131_072 else {
                closeTransport(
                    event: "transport_offer_invalid",
                    errorCode: "webrtc_offer_invalid"
                )
                return
            }
            negotiate(sdpOffer: sdp, operationID: operationID)
        case "microphone_acquired":
            guard object["operationId"] as? String == activeOperationID else { return }
            recordE2EMediaEvent(.microphoneAcquired)
        case "remote_audio_track":
            guard object["operationId"] as? String == activeOperationID else { return }
            recordE2EMediaEvent(.remoteAudioTrackReceived)
        case "remote_audio_playing":
            guard object["operationId"] as? String == activeOperationID else { return }
            recordE2EMediaEvent(.remoteAudioPlaybackSucceeded)
        case "remote_audio_playback_failed":
            guard object["operationId"] as? String == activeOperationID else { return }
            recordE2EMediaEvent(.remoteAudioPlaybackFailed)
        case "attached":
            guard object["operationId"] as? String == activeOperationID else { return }
            sessionStarting = false
            MacOSVoiceE2EPerformanceStore.shared?.recordTransportAttached()
            runtimeHost?.markTransportAttached()
            resolveStart(.success(()))
        case "detached":
            guard object["operationId"] as? String == activeOperationID else { return }
            sessionStarting = false
            activeOperationID = nil
            MacOSVoiceE2EReceiptStore.shared?.recordSafeClose()
            resolveStart(.failure(CodexVoiceWebRTCTransportError.transportClosed))
            let reconnectExpected = object["reconnectExpected"] as? Bool ?? true
            runtimeHost?.markTransportDetached(reconnectExpected: reconnectExpected)
        case "failure":
            guard object["operationId"] as? String == activeOperationID else { return }
            closeTransport(
                event: "transport_failure",
                errorCode: Self.safeErrorCode(object["code"] as? String)
            )
        default:
            closeTransport(
                event: "transport_message_unknown",
                errorCode: "webrtc_message_unknown"
            )
        }
    }

    func consumeMicrophonePermission() -> Bool {
        runtimeHost?.consumeMicrophonePermission() ?? false
    }

    private func recordE2EMediaEvent(_ event: MacOSVoiceE2EMediaEvent) {
        guard let receiptStore = MacOSVoiceE2EReceiptStore.shared else { return }
        receiptStore.recordMediaEvent(event)
        guard let attemptID = receiptStore.claimPhysicalConfirmationRequest() else { return }
        Task { @MainActor in
            let confirmed = await MacOSVoiceE2EPhysicalMediaConfirmation.present()
            receiptStore.recordPhysicalMediaUserConfirmation(
                confirmed,
                attemptID: attemptID
            )
        }
    }

    private func negotiate(sdpOffer: String, operationID: String) {
        let generation = transportGeneration
        guard let runtimeHost else { return }
        Task { @MainActor [weak self] in
            do {
                let answer = try await runtimeHost.startWebRTC(sdpOffer: sdpOffer)
                guard let self,
                      self.sessionStarting,
                      self.transportGeneration == generation,
                      self.activeOperationID == operationID else {
                    return
                }
                self.callAsync(
                    "return await window.hoverPocketVoice.acceptAnswer(operationId, answer);",
                    arguments: ["operationId": operationID, "answer": answer.sdp]
                ) { [weak self] error in
                    guard let self,
                          self.activeOperationID == operationID,
                          error != nil else { return }
                    self.closeTransport(
                        event: "transport_answer_failed",
                        errorCode: "webrtc_answer_failed"
                    )
                }
            } catch {
                guard let self,
                      self.transportGeneration == generation,
                      self.activeOperationID == operationID else { return }
                let errorCode = self.runtimeHost?.snapshot.lastErrorCode
                    ?? "webrtc_negotiation_failed"
                self.closeTransport(
                    event: "transport_negotiation_failed",
                    errorCode: errorCode
                )
            }
        }
    }

    private func closeTransport(
        event: String,
        errorCode: String? = nil,
        clearTransientUIState: Bool = false,
        requestRealtimeStop: Bool = true
    ) {
        transportGeneration &+= 1
        let cleanupGeneration = transportGeneration
        sessionStarting = false
        activeOperationID = nil
        MacOSVoiceE2EReceiptStore.shared?.recordMediaEvent(.microphoneStopped)
        MacOSVoiceE2EReceiptStore.shared?.recordMediaEvent(.remoteAudioTrackStopped)
        MacOSVoiceE2EReceiptStore.shared?.recordMediaEvent(.remoteAudioPlaybackStopped)
        MacOSVoiceE2EReceiptStore.shared?.recordSafeClose()
        resolveStart(.failure(CodexVoiceWebRTCTransportError.transportClosed))
        evaluate("window.hoverPocketVoice.cleanup(false)")
        guard let runtimeHost else { return }
        if clearTransientUIState {
            runtimeHost.clearTransientUIState()
        }
        guard requestRealtimeStop else {
            if let errorCode {
                runtimeHost.markSessionFailure(errorCode)
            }
            return
        }
        Task { @MainActor [weak self, weak runtimeHost] in
            guard let self, let runtimeHost else { return }
            await runtimeHost.stopRealtime()
            guard self.transportGeneration == cleanupGeneration,
                  self.runtimeHost === runtimeHost else { return }
            if let errorCode {
                runtimeHost.markSessionFailure(errorCode)
            }
        }
    }

    private func resolveStart(_ result: Result<Void, Error>) {
        startTimeoutTask?.cancel()
        startTimeoutTask = nil
        let continuation = startContinuation
        startContinuation = nil
        continuation?.resume(with: result)
    }

    private func evaluate(
        _ source: String,
        completion: ((Error?) -> Void)? = nil
    ) {
        guard let webView else {
            completion?(CodexVoiceWebRTCTransportError.webViewUnavailable)
            return
        }
        webView.evaluateJavaScript(source) { _, error in
            completion?(error)
        }
    }

    private func callAsync(
        _ body: String,
        arguments: [String: Any],
        completion: @escaping (Error?) -> Void
    ) {
        guard let webView else {
            completion(CodexVoiceWebRTCTransportError.webViewUnavailable)
            return
        }
        webView.callAsyncJavaScript(
            body,
            arguments: arguments,
            in: nil,
            in: .page
        ) { result in
            switch result {
            case .success:
                completion(nil)
            case .failure(let error):
                completion(error)
            }
        }
    }

    private static func safeErrorCode(_ value: String?) -> String {
        guard let value else { return "webrtc_failed" }
        let allowed = value.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122, 95:
                true
            default:
                false
            }
        }
        let bounded = String(String.UnicodeScalarView(allowed.prefix(64)))
        return bounded.isEmpty ? "webrtc_failed" : bounded
    }
}

enum CodexVoiceSystemMicrophoneAuthorizationDecision: Equatable {
    case proceed
    case request
    case deny
}

enum CodexVoiceSystemMicrophoneAuthorizationPolicy {
    static func decision(
        for status: AVAuthorizationStatus
    ) -> CodexVoiceSystemMicrophoneAuthorizationDecision {
        switch status {
        case .authorized:
            .proceed
        case .notDetermined:
            .request
        case .denied, .restricted:
            .deny
        @unknown default:
            .deny
        }
    }
}

struct CodexVoiceWebRTCTransportView: NSViewRepresentable {
    @ObservedObject var driver: CodexVoiceWebRTCDriver

    func makeCoordinator() -> Coordinator {
        Coordinator(driver: driver)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.userContentController.add(
            context.coordinator,
            name: Coordinator.messageHandlerName
        )
        configuration.setURLSchemeHandler(
            context.coordinator.schemeHandler,
            forURLScheme: CodexVoiceWebContent.scheme
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.isHidden = false
        driver.attach(webView: webView)
        webView.load(URLRequest(url: CodexVoiceWebContent.pageURL))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if webView.url == nil && !webView.isLoading {
            webView.load(URLRequest(url: CodexVoiceWebContent.pageURL))
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: Coordinator.messageHandlerName
        )
        coordinator.driver?.detach(webView: webView)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        static let messageHandlerName = "hoverPocketVoice"

        weak var driver: CodexVoiceWebRTCDriver?
        fileprivate let schemeHandler = CodexVoiceWebContentSchemeHandler()

        init(driver: CodexVoiceWebRTCDriver) {
            self.driver = driver
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == Self.messageHandlerName,
                  message.frameInfo.isMainFrame,
                  CodexVoiceWebContent.isTrusted(message.frameInfo.request.url) else {
                return
            }
            driver?.handleMessage(message.body)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            decisionHandler(
                CodexVoiceWebContent.isTrusted(navigationAction.request.url)
                    ? .allow
                    : .cancel
            )
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            nil
        }

        func webView(
            _ webView: WKWebView,
            requestMediaCapturePermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            type: WKMediaCaptureType,
            decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
        ) {
            let structurallyAllowed = CodexVoiceMediaPermissionPolicy.shouldAllow(
                scheme: origin.protocol,
                host: origin.host,
                port: origin.port,
                frameURL: frame.request.url,
                isMainFrame: frame.isMainFrame,
                microphoneOnly: type == .microphone,
                armed: true
            )
            let armed = structurallyAllowed && (driver?.consumeMicrophonePermission() ?? false)
            decisionHandler(armed ? .grant : .deny)
        }
    }
}

enum CodexVoiceMediaPermissionPolicy {
    static func shouldAllow(
        scheme: String,
        host: String,
        port: Int,
        frameURL: URL?,
        isMainFrame: Bool,
        microphoneOnly: Bool,
        armed: Bool
    ) -> Bool {
        armed
            && isMainFrame
            && microphoneOnly
            && scheme == CodexVoiceWebContent.scheme
            && host == CodexVoiceWebContent.host
            && port == 0
            && CodexVoiceWebContent.isTrusted(frameURL)
    }
}

private enum CodexVoiceWebContent {
    static let scheme = "hoverpocket-voice"
    static let host = "local"
    static let pageURL = URL(string: "\(scheme)://\(host)/index.html")!

    static func isTrusted(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == scheme
            && url.host == host
            && url.port == nil
            && url.path == "/index.html"
            && url.query == nil
            && url.fragment == nil
    }

    static let html = #"""
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; media-src blob:; connect-src 'none'; webrtc 'allow'; img-src 'none'; font-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
  <style>html,body{width:1px;height:1px;margin:0;overflow:hidden;background:transparent}</style>
</head>
<body>
<script>
(() => {
  "use strict";
  const bridge = window.webkit.messageHandlers.hoverPocketVoice;
  let peer = null;
  let microphone = null;
  let remoteAudio = null;
  let attached = false;
  let operationEpoch = 0;
  let activeOperationId = null;

  function post(message) {
    bridge.postMessage(message);
  }

  function waitForIce(connection) {
    if (connection.iceGatheringState === "complete") return Promise.resolve();
    return new Promise((resolve, reject) => {
      const timeout = window.setTimeout(() => {
        connection.removeEventListener("icegatheringstatechange", onChange);
        reject(new Error("ice_timeout"));
      }, 8000);
      const onChange = () => {
        if (connection.iceGatheringState !== "complete") return;
        window.clearTimeout(timeout);
        connection.removeEventListener("icegatheringstatechange", onChange);
        resolve();
      };
      connection.addEventListener("icegatheringstatechange", onChange);
    });
  }

  function isCurrentOperation(epoch, operationId) {
    return epoch === operationEpoch && operationId === activeOperationId;
  }

  function cleanup(notify, reconnectExpected = true) {
    const wasAttached = attached;
    const operationId = activeOperationId;
    operationEpoch += 1;
    activeOperationId = null;
    attached = false;
    if (peer) {
      peer.close();
      peer = null;
    }
    if (microphone) {
      microphone.getTracks().forEach((track) => track.stop());
      microphone = null;
    }
    if (remoteAudio) {
      remoteAudio.pause();
      remoteAudio.srcObject = null;
      remoteAudio = null;
    }
    if (notify && wasAttached && operationId) {
      post({ type: "detached", operationId, reconnectExpected });
    }
  }

  async function start(operationId) {
    if (typeof operationId !== "string" || !operationId) {
      throw new Error("operation_invalid");
    }
    cleanup(false);
    const epoch = operationEpoch;
    activeOperationId = operationId;
    let acquiredMicrophone = null;
    try {
      acquiredMicrophone = await navigator.mediaDevices.getUserMedia({
        audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true },
        video: false
      });
      if (!isCurrentOperation(epoch, operationId)) {
        acquiredMicrophone.getTracks().forEach((track) => track.stop());
        return;
      }
      microphone = acquiredMicrophone;
      post({ type: "microphone_acquired", operationId });
      const connection = new RTCPeerConnection();
      peer = connection;
      connection.createDataChannel("oai-events");
      microphone.getAudioTracks().forEach((track) => connection.addTrack(track, microphone));
      connection.addEventListener("track", (event) => {
        if (!isCurrentOperation(epoch, operationId) || connection !== peer) return;
        post({ type: "remote_audio_track", operationId });
        remoteAudio ||= new Audio();
        remoteAudio.autoplay = true;
        remoteAudio.srcObject = event.streams[0] || new MediaStream([event.track]);
        remoteAudio.play()
          .then(() => post({ type: "remote_audio_playing", operationId }))
          .catch(() => post({ type: "remote_audio_playback_failed", operationId }));
      });
      connection.addEventListener("connectionstatechange", () => {
        if (!isCurrentOperation(epoch, operationId) || connection !== peer) return;
        if (["failed", "disconnected", "closed"].includes(connection.connectionState)) {
          cleanup(true, true);
        }
      });
      const offer = await connection.createOffer({ offerToReceiveAudio: true });
      if (!isCurrentOperation(epoch, operationId) || connection !== peer) return;
      await connection.setLocalDescription(offer);
      await waitForIce(connection);
      if (!isCurrentOperation(epoch, operationId) || connection !== peer) return;
      const sdp = connection.localDescription && connection.localDescription.sdp;
      if (!sdp) throw new Error("offer_missing");
      post({ type: "offer", operationId, sdp });
    } catch (error) {
      if (!isCurrentOperation(epoch, operationId)) {
        if (acquiredMicrophone && acquiredMicrophone !== microphone) {
          acquiredMicrophone.getTracks().forEach((track) => track.stop());
        }
        return;
      }
      const code = error && error.name === "NotAllowedError"
        ? "microphone_denied"
        : "webrtc_failed";
      cleanup(false);
      post({ type: "failure", operationId, code });
    }
  }

  async function acceptAnswer(operationId, sdp) {
    const epoch = operationEpoch;
    const connection = peer;
    if (!isCurrentOperation(epoch, operationId) || !connection || typeof sdp !== "string") {
      throw new Error("answer_invalid");
    }
    await connection.setRemoteDescription({ type: "answer", sdp });
    if (!isCurrentOperation(epoch, operationId) || connection !== peer) return;
    attached = true;
    post({ type: "attached", operationId });
  }

  function setMuted(muted) {
    if (!microphone) return;
    microphone.getAudioTracks().forEach((track) => {
      track.enabled = !muted;
    });
  }

  window.hoverPocketVoice = { start, acceptAnswer, setMuted, cleanup };
  post({ type: "ready" });
})();
</script>
</body>
</html>
"""#
}

enum CodexVoiceWebRTCEmbeddedContract {
    static func verifyOperationEpoch() -> Bool {
        let requiredFragments = [
            "let operationEpoch = 0;",
            "let activeOperationId = null;",
            "function isCurrentOperation(epoch, operationId)",
            "acquiredMicrophone.getTracks().forEach((track) => track.stop());",
            "post({ type: \"microphone_acquired\", operationId });",
            "post({ type: \"offer\", operationId, sdp });",
            "async function acceptAnswer(operationId, sdp)",
            "post({ type: \"remote_audio_track\", operationId });",
            "post({ type: \"remote_audio_playing\", operationId })",
            "post({ type: \"attached\", operationId });"
        ]
        return requiredFragments.allSatisfy(CodexVoiceWebContent.html.contains)
    }
}

@MainActor
fileprivate final class CodexVoiceWebContentSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard CodexVoiceWebContent.isTrusted(urlSchemeTask.request.url) else {
            urlSchemeTask.didFailWithError(CodexVoiceWebRTCTransportError.untrustedURL)
            return
        }
        let data = Data(CodexVoiceWebContent.html.utf8)
        let response = URLResponse(
            url: CodexVoiceWebContent.pageURL,
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

enum CodexVoiceWebRTCTransportError: Error {
    case webViewUnavailable
    case untrustedURL
    case microphoneRequestNotArmed
    case microphonePermissionDenied
    case transportClosed
}
