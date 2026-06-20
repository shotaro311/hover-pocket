@preconcurrency import AVFoundation
import AppKit
import OSLog
import SwiftUI

struct MirrorPreviewView: View {
    let isActive: Bool
    @ObservedObject var settings: AppSettings
    @StateObject private var camera = MirrorCameraModel.shared
    @StateObject private var microphone = MirrorMicrophoneModel.shared

    var body: some View {
        VStack(spacing: settings.showMirrorMicrophoneCheck ? 8 : 0) {
            mirrorSurface

            if settings.showMirrorMicrophoneCheck {
                microphoneCheckRow
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .onAppear {
            camera.setActive(isActive)
            syncMicrophoneMonitoring()
        }
        .onDisappear {
            camera.setActive(false)
            microphone.setMonitoringActive(false)
        }
        .onChange(of: isActive) { _, newValue in
            camera.setActive(newValue)
            syncMicrophoneMonitoring()
        }
        .onChange(of: settings.showMirrorMicrophoneCheck) { _, isVisible in
            syncMicrophoneMonitoring()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            camera.recheckPermissionAfterExternalChange()
        }
    }

    private var mirrorSurface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black)

            CameraPreviewView(
                session: camera.session,
                onReady: {
                    camera.markPreviewReady()
                }
            )
            .scaleEffect(x: -1, y: 1)
            .opacity(camera.shouldShowPreview ? 1 : 0)
            .animation(.easeOut(duration: 0.06), value: camera.shouldShowPreview)

            LinearGradient(
                colors: [
                    .black.opacity(0.18),
                    .clear,
                    .black.opacity(0.24)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            statusOverlay
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var microphoneCheckRow: some View {
        HStack(spacing: 9) {
            Image(systemName: microphoneIconName)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(microphoneAccentColor)
                .frame(width: 18)

            Text(microphoneTitle)
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)

            audioBars
                .frame(width: 92)

            Text(microphone.inputName)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.42))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            if microphoneNeedsPrivacySettings {
                Button {
                    SystemSettingsOpener.openMicrophonePrivacy()
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 10.5, weight: .bold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.84))
                .background(
                    Circle()
                        .fill(Color.yellow.opacity(0.24))
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
                .contentShape(Circle())
                .help("Open Microphone Privacy Settings")
            } else {
                Button {
                    microphone.toggleRecordingPlayback()
                } label: {
                    Image(systemName: microphoneControlIconName)
                        .font(.system(size: 10.5, weight: .bold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.84))
                .background(
                    Circle()
                        .fill(microphoneControlFillColor)
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
                .contentShape(Circle())
                .disabled(!microphone.canUseRecordingControl)
                .opacity(microphone.canUseRecordingControl ? 1 : 0.42)
                .help(microphoneControlHelp)
            }
        }
        .frame(height: 34)
        .padding(.horizontal, 11)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var audioBars: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<12, id: \.self) { index in
                let threshold = Double(index + 1) / 12.0
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(microphone.level >= threshold ? microphoneAccentColor : Color.white.opacity(0.13))
                    .frame(width: 4, height: barHeight(at: index))
            }
        }
        .animation(.easeOut(duration: 0.08), value: microphone.level)
    }

    private func syncMicrophoneMonitoring() {
        microphone.setMonitoringActive(isActive && settings.showMirrorMicrophoneCheck)
    }

    private var microphoneIconName: String {
        switch microphone.status {
        case .running:
            return "mic.fill"
        case .requestingPermission:
            return "mic.badge.plus"
        case .denied, .restricted:
            return "mic.slash.fill"
        case .unavailable, .failed:
            return "exclamationmark.triangle.fill"
        case .idle:
            return "mic"
        }
    }

    private var microphoneTitle: String {
        microphoneNeedsPrivacySettings ? "Enable Mic" : "Mic Check"
    }

    private var microphoneNeedsPrivacySettings: Bool {
        switch microphone.status {
        case .denied, .restricted:
            return true
        default:
            return false
        }
    }

    private var microphoneAccentColor: Color {
        switch microphone.status {
        case .running:
            return .green.opacity(0.86)
        case .denied, .restricted, .unavailable, .failed:
            return .yellow.opacity(0.90)
        default:
            return .cyan.opacity(0.74)
        }
    }

    private var microphoneControlIconName: String {
        switch microphone.recordingState {
        case .idle:
            return "record.circle"
        case .recording:
            return "stop.fill"
        case .readyToPlay:
            return "play.fill"
        case .playing:
            return "stop.fill"
        }
    }

    private var microphoneControlFillColor: Color {
        switch microphone.recordingState {
        case .recording:
            return .red.opacity(0.46)
        case .readyToPlay:
            return .green.opacity(0.24)
        case .playing:
            return .green.opacity(0.38)
        case .idle:
            return .white.opacity(0.10)
        }
    }

    private var microphoneControlHelp: String {
        switch microphone.recordingState {
        case .idle:
            return "Record a temporary mic sample"
        case .recording:
            return "Stop recording"
        case .readyToPlay:
            return "Play temporary mic sample"
        case .playing:
            return "Stop playback and clear"
        }
    }

    private func barHeight(at index: Int) -> CGFloat {
        let pattern: [CGFloat] = [7, 10, 14, 18, 22, 17, 12, 20, 15, 11, 16, 9]
        return pattern[index % pattern.count]
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch camera.status {
        case .idle:
            if isActive {
                loadingOverlay(text: "Starting camera")
            }
        case .requestingPermission:
            loadingOverlay(text: "Camera permission")
        case .starting:
            loadingOverlay(text: "Starting camera")
        case .running:
            EmptyView()
        case .denied:
            messageOverlay(
                symbol: "camera.fill",
                title: "Camera access is off",
                message: "Enable camera access in System Settings.",
                actionTitle: "Open Camera Settings",
                action: {
                    camera.openCameraPrivacySettings()
                }
            )
        case .restricted:
            messageOverlay(
                symbol: "lock.fill",
                title: "Camera is restricted",
                message: "macOS is blocking camera access.",
                actionTitle: "Open Camera Settings",
                action: {
                    camera.openCameraPrivacySettings()
                }
            )
        case .unavailable:
            messageOverlay(
                symbol: "video.slash.fill",
                title: "Camera not found",
                message: "No available Mac camera was detected."
            )
        case let .failed(message):
            messageOverlay(
                symbol: "exclamationmark.triangle.fill",
                title: "Camera failed",
                message: message
            )
        }
    }

    private func loadingOverlay(text: String) -> some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(.white.opacity(0.78))

            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.70))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 12))
    }

    private func messageOverlay(
        symbol: String,
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))

            Text(title)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.88))

            Text(message)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.52))

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .buttonStyle(.plain)
                    .foregroundStyle(.black.opacity(0.86))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.82), in: Capsule())
                    .help(actionTitle)
            }
        }
        .padding(18)
        .frame(maxWidth: 280)
        .background(Color.black.opacity(0.54), in: RoundedRectangle(cornerRadius: 14))
    }
}

@MainActor
final class MirrorCameraModel: ObservableObject {
    private static let logger = Logger(subsystem: "local.codex.hover-pocket", category: "mirror-camera")
    static let shared = MirrorCameraModel()

    let session: AVCaptureSession
    @Published private(set) var status: MirrorCameraStatus = .idle

    private let sessionBox = CameraSessionBox()
    private let sessionQueue = DispatchQueue(label: "local.codex.hover-pocket.camera")
    private let stopGrace: TimeInterval = 4
    private var isPreparing = false
    private var isSessionPrepared = false
    private var isRequestingPermission = false
    private var isStarting = false
    private var isSessionRunning = false
    private var isPreviewReady = false
    private var wantsCamera = false
    private var runIntentVersion = 0
    private var pendingStopTask: DispatchWorkItem?
    private var permissionRecoveryTask: DispatchWorkItem?
    private var permissionRecoveryAttempts = 0

    init() {
        self.session = sessionBox.session
        prepareIfAuthorized()
    }

    var shouldShowPreview: Bool {
        switch status {
        case .starting, .running:
            return true
        default:
            return false
        }
    }

    func setActive(_ active: Bool) {
        guard wantsCamera != active else {
            if active {
                runIntentVersion += 1
                pendingStopTask?.cancel()
                pendingStopTask = nil
                prepareIfAuthorized()
                activate()
            }
            return
        }

        runIntentVersion += 1
        wantsCamera = active

        if active {
            pendingStopTask?.cancel()
            pendingStopTask = nil
            prepareIfAuthorized()
            activate()
        } else {
            stopPermissionRecoveryPolling()
            updateStatus(.idle)
            scheduleStopSession()
        }
    }

    func openCameraPrivacySettings() {
        SystemSettingsOpener.openCameraPrivacy()
        startPermissionRecoveryPolling()
    }

    func recheckPermissionAfterExternalChange() {
        guard wantsCamera else { return }
        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
            isRequestingPermission = false
            if status == .denied || status == .restricted || status == .requestingPermission {
                isStarting = false
            }
        }
        prepareIfAuthorized()
        activate()
    }

    func markPreviewReady() {
        isPreviewReady = true
        prepareIfAuthorized()

        if wantsCamera {
            activate()
        }
    }

    func prepareIfAuthorized() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        prepareSessionIfNeeded()
    }

    private func prepareSessionIfNeeded() {
        guard !isPreparing, !isSessionPrepared else { return }

        isPreparing = true
        Self.logger.notice("camera session prepare requested")

        sessionQueue.async { [weak self, sessionBox] in
            do {
                try sessionBox.configureIfNeeded()
            } catch {
                Task { @MainActor in
                    guard let self else { return }
                    self.isPreparing = false
                    if self.wantsCamera {
                        self.updateStatus(Self.status(for: error))
                    }
                }
                return
            }

            Task { @MainActor in
                guard let self else { return }
                self.isPreparing = false
                self.isSessionPrepared = true
                Self.logger.notice("camera session prepared")
            }
        }
    }

    private func activate() {
        guard isPreviewReady else {
            updateStatus(.starting)
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession()
        case .notDetermined:
            requestPermission()
        case .denied:
            isStarting = false
            isSessionRunning = false
            updateStatus(.denied)
        case .restricted:
            isStarting = false
            isSessionRunning = false
            updateStatus(.restricted)
        @unknown default:
            isStarting = false
            isSessionRunning = false
            updateStatus(.failed("Unknown camera permission state."))
        }
    }

    private func requestPermission() {
        guard !isRequestingPermission else { return }

        isRequestingPermission = true
        updateStatus(.requestingPermission)
        Self.logger.notice("camera permission requested")

        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }

                self.isRequestingPermission = false
                Self.logger.notice("camera permission result: \(granted ? "granted" : "denied", privacy: .public)")
                guard self.wantsCamera else {
                    self.updateStatus(.idle)
                    return
                }

                granted ? self.startSession() : self.updateStatus(.denied)
            }
        }
    }

    private func startSession() {
        guard !isStarting else { return }
        stopPermissionRecoveryPolling()

        isStarting = true
        if !isSessionRunning {
            updateStatus(.starting)
        }
        Self.logger.notice("camera session start requested")

        sessionQueue.async { [weak self, sessionBox] in
            do {
                try sessionBox.configureIfNeeded()

                if !sessionBox.session.isRunning {
                    sessionBox.session.startRunning()
                }
            } catch {
                Task { @MainActor in
                    guard let self else { return }
                    self.isStarting = false
                    self.updateStatus(Self.status(for: error))
                }
                return
            }

            Task { @MainActor in
                guard let self else { return }

                self.isStarting = false
                guard self.wantsCamera else {
                    self.scheduleStopSession()
                    return
                }

                self.isSessionPrepared = true
                self.isSessionRunning = sessionBox.session.isRunning
                if self.isSessionRunning {
                    Self.logger.notice("camera session running")
                }
                self.updateStatus(self.isSessionRunning ? .running : .failed("Camera did not start."))
            }
        }
    }

    private func scheduleStopSession() {
        stopPermissionRecoveryPolling()
        pendingStopTask?.cancel()
        let stopIntentVersion = runIntentVersion
        let task = DispatchWorkItem { [weak self] in
            self?.stopSessionNow(for: stopIntentVersion)
        }

        pendingStopTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + stopGrace, execute: task)
    }

    private func stopSessionNow(for intentVersion: Int) {
        guard intentVersion == runIntentVersion, !wantsCamera else { return }
        isStarting = false
        pendingStopTask = nil

        sessionQueue.async { [weak self, sessionBox] in
            let wasRunning = sessionBox.session.isRunning
            if sessionBox.session.isRunning {
                sessionBox.session.stopRunning()
            }

            Task { @MainActor in
                guard let self else { return }
                self.isSessionRunning = false
                if wasRunning {
                    Self.logger.notice("camera session stopped")
                }
                guard intentVersion == self.runIntentVersion, !self.wantsCamera else {
                    Self.logger.notice("stale camera stop completed after reactivation; restarting")
                    self.startSession()
                    return
                }
                if !self.wantsCamera, self.status != .denied, self.status != .restricted {
                    self.updateStatus(.idle)
                }
            }
        }
    }

    private func updateStatus(_ newStatus: MirrorCameraStatus) {
        guard status != newStatus else { return }
        status = newStatus
    }

    private func startPermissionRecoveryPolling() {
        guard wantsCamera else { return }
        permissionRecoveryAttempts = 0
        schedulePermissionRecoveryPoll()
    }

    private func schedulePermissionRecoveryPoll() {
        permissionRecoveryTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.pollPermissionRecovery()
        }
        permissionRecoveryTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: task)
    }

    private func pollPermissionRecovery() {
        permissionRecoveryTask = nil
        guard wantsCamera else {
            permissionRecoveryAttempts = 0
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permissionRecoveryAttempts = 0
            prepareIfAuthorized()
            activate()
        case .notDetermined:
            permissionRecoveryAttempts = 0
            activate()
        case .denied, .restricted:
            permissionRecoveryAttempts += 1
            if permissionRecoveryAttempts < 120 {
                schedulePermissionRecoveryPoll()
            }
        @unknown default:
            permissionRecoveryAttempts = 0
            updateStatus(.failed("Unknown camera permission state."))
        }
    }

    private func stopPermissionRecoveryPolling() {
        permissionRecoveryTask?.cancel()
        permissionRecoveryTask = nil
        permissionRecoveryAttempts = 0
    }

    private static func status(for error: Error) -> MirrorCameraStatus {
        if let mirrorError = error as? MirrorCameraError {
            switch mirrorError {
            case .noCamera:
                return .unavailable
            case .inputUnavailable:
                return .failed(mirrorError.localizedDescription)
            }
        }

        return .failed(error.localizedDescription)
    }
}

enum MirrorCameraStatus: Equatable {
    case idle
    case requestingPermission
    case starting
    case running
    case denied
    case restricted
    case unavailable
    case failed(String)
}

enum MirrorCameraError: LocalizedError {
    case noCamera
    case inputUnavailable

    var errorDescription: String? {
        switch self {
        case .noCamera:
            "No available camera was detected."
        case .inputUnavailable:
            "The selected camera input cannot be used."
        }
    }
}

final class CameraSessionBox: @unchecked Sendable {
    let session = AVCaptureSession()
    private var isConfigured = false

    func configureIfNeeded() throws {
        guard !isConfigured else { return }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video) else {
            throw MirrorCameraError.noCamera
        }

        let input = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()
        session.sessionPreset = .vga640x480

        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw MirrorCameraError.inputUnavailable
        }

        session.addInput(input)
        session.commitConfiguration()
        isConfigured = true
    }
}
