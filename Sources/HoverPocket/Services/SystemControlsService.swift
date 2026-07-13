import AppKit
import AudioToolbox
import CoreGraphics
import CoreAudio
import Darwin
import Foundation
import os

private let mediaLog = Logger(subsystem: "local.codex.hover-pocket", category: "MediaControls")

@MainActor
final class ControlsStore: ObservableObject {
    static let shared = ControlsStore()

    @Published private(set) var displays: [ControlsDisplay] = []
    @Published private(set) var volume: ControlsVolumeState = .empty
    @Published private(set) var nowPlaying: ControlsNowPlayingState = .empty
    @Published private(set) var isPlaybackCommandPending = false
    @Published private(set) var isPlaybackRateCommandPending = false

    private let brightnessService = DisplayBrightnessService()
    private let volumeService = SystemVolumeService()
    private let mediaService = MediaRemoteService()
    private var pollTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var nowPlayingRefreshTask: Task<Void, Never>?
    private var playbackCommandTask: Task<Void, Never>?
    private var playbackRateCommandTask: Task<Void, Never>?
    private var playbackCommandRequestID = 0
    private var playbackRateRequestID = 0
    private var pendingPlaybackTarget: Bool?
    private var isMediaStreamActive = false
    private var lastAdapterEvent: AdapterNowPlaying?
    private var mediaEventCounter = 0
    private var enrichmentTask: Task<Void, Never>?

    func startPolling() {
        startMediaStreamIfAvailable()
        refresh()
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        timer.tolerance = 0.25
        pollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        refreshTask?.cancel()
        refreshTask = nil
        nowPlayingRefreshTask?.cancel()
        nowPlayingRefreshTask = nil
        playbackCommandTask?.cancel()
        playbackCommandTask = nil
        playbackRateCommandTask?.cancel()
        playbackRateCommandTask = nil
        enrichmentTask?.cancel()
        enrichmentTask = nil
        playbackCommandRequestID += 1
        playbackRateRequestID += 1
        pendingPlaybackTarget = nil
        mediaEventCounter += 1
        isPlaybackCommandPending = false
        isPlaybackRateCommandPending = false
        mediaService.stopNowPlayingStream()
        isMediaStreamActive = false
        lastAdapterEvent = nil
    }

    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let shouldRefreshMedia = !isPlaybackCommandPending
                && !isPlaybackRateCommandPending
                && !isMediaStreamActive
            let displays = await brightnessService.displays()
            guard !Task.isCancelled else { return }
            let nextVolume = await volumeService.currentState()
            let nextNowPlaying = shouldRefreshMedia ? await mediaService.nowPlaying() : nil
            guard !Task.isCancelled else { return }
            self.displays = displays
            self.volume = nextVolume
            if let nextNowPlaying, !isPlaybackCommandPending, !isPlaybackRateCommandPending, !isMediaStreamActive {
                self.nowPlaying = nextNowPlaying
            }
            if isMediaStreamActive {
                self.updateExtrapolatedProgress()
            }
        }
    }

    // MARK: - Adapter event stream

    /// adapter が使える環境では、2秒ポーリングではなく Now Playing の変更通知で
    /// メディア状態を更新する。ポーリングはディスプレイ/音量の取得に限定される。
    private func startMediaStreamIfAvailable() {
        guard !isMediaStreamActive, mediaService.isAdapterAvailable else { return }
        isMediaStreamActive = true
        mediaService.startNowPlayingStream { [weak self] event in
            Task { @MainActor in
                self?.applyAdapterEvent(event)
            }
        }
    }

    private func applyAdapterEvent(_ event: AdapterNowPlaying?) {
        guard isMediaStreamActive else { return }
        // 倍速操作の途中経過でイベントが割り込むと UI が暴れるため、確定後の
        // refreshNowPlaying に任せる。play/pause はイベント自体が確定情報なので通す。
        guard !isPlaybackRateCommandPending else { return }
        mediaEventCounter += 1
        let eventID = mediaEventCounter
        lastAdapterEvent = event

        guard let event else {
            nowPlaying = .empty
            enrichmentTask?.cancel()
            return
        }

        var state = MediaRemoteService.state(fromAdapter: event)
        if state.title == nowPlaying.title {
            // 同一メディアの更新では、ブラウザ enrichment 済みの情報を引き継いで
            // プレビューやアートワークのちらつきを防ぐ
            state.mediaURLString = nowPlaying.mediaURLString
            state.previewWindowID = nowPlaying.previewWindowID
            if state.artworkData == nil {
                state.artworkData = nowPlaying.artworkData
            }
        }
        nowPlaying = state

        if isPlaybackCommandPending, pendingPlaybackTarget == state.isPlaying {
            isPlaybackCommandPending = false
            pendingPlaybackTarget = nil
            playbackCommandTask?.cancel()
            playbackCommandTask = nil
        }

        enrichmentTask?.cancel()
        let service = mediaService
        enrichmentTask = Task { [weak self] in
            let enriched = await service.enrich(state)
            guard !Task.isCancelled else { return }
            guard let self, self.mediaEventCounter == eventID else { return }
            guard !self.isPlaybackRateCommandPending else { return }
            self.nowPlaying = enriched
        }
    }

    private func updateExtrapolatedProgress() {
        guard let lastAdapterEvent, nowPlaying.hasMedia, nowPlaying.isPlaying else { return }
        let progress = lastAdapterEvent.extrapolatedElapsed
        let upperBound = nowPlaying.duration > 0 ? nowPlaying.duration : progress
        nowPlaying.progress = progress.clamped(to: 0...max(upperBound, 0))
    }

    func setBrightness(_ brightness: Double, for displayID: ControlsDisplay.ID) {
        guard let index = displays.firstIndex(where: { $0.id == displayID }) else { return }
        guard displays[index].isControllable else { return }
        let normalized = brightness.clamped(to: DisplayBrightnessService.minimumBrightness...1)
        let cgDisplayID = CGDirectDisplayID(displays[index].displayID)
        displays[index].brightness = normalized
        _ = brightnessService.setBrightness(normalized, for: cgDisplayID)
    }

    func toggleDisplayBrightness(for displayID: ControlsDisplay.ID) {
        guard let display = displays.first(where: { $0.id == displayID }) else { return }
        guard display.isControllable else { return }
        let target = display.brightness <= DisplayBrightnessService.minimumBrightness + 0.005
            ? 1.0
            : DisplayBrightnessService.minimumBrightness
        setBrightness(target, for: displayID)
    }

    func setVolumeLevel(_ level: Double) {
        let normalized = level.clamped(to: 0...1)
        volume.level = normalized
        if normalized > 0, volume.isMuted {
            volume.isMuted = false
        }
        Task {
            await volumeService.setVolume(normalized)
            await MainActor.run {
                self.refresh()
            }
        }
    }

    func toggleMute() {
        let target = !volume.isMuted
        volume.isMuted = target
        Task {
            await volumeService.setMuted(target)
            await MainActor.run {
                self.refresh()
            }
        }
    }

    func setPlaybackProgress(_ progress: TimeInterval) {
        guard nowPlaying.hasMedia, nowPlaying.duration > 0 else { return }
        let target = progress.clamped(to: 0...nowPlaying.duration)
        nowPlaying.progress = target
        // 外挿の基準もシーク先へ動かし、次のイベントが届くまでの巻き戻りを防ぐ
        lastAdapterEvent?.elapsed = target
        lastAdapterEvent?.timestamp = Date()
        let service = mediaService
        Task.detached(priority: .userInitiated) {
            await service.setElapsedTime(target)
        }
    }

    func skipPlayback(by seconds: TimeInterval) {
        setPlaybackProgress(nowPlaying.progress + seconds)
    }

    func restartPlayback() {
        setPlaybackProgress(0)
    }

    func playPreviousTrack() {
        guard nowPlaying.hasMedia else { return }
        let service = mediaService
        Task.detached(priority: .userInitiated) {
            await service.previousTrack()
        }
    }

    func playNextTrack() {
        guard nowPlaying.hasMedia else { return }
        let service = mediaService
        Task.detached(priority: .userInitiated) {
            await service.nextTrack()
        }
    }

    func togglePlayback() {
        guard nowPlaying.hasMedia, !isPlaybackCommandPending else { return }
        nowPlaying.isPlaying.toggle()
        playbackCommandRequestID += 1
        let requestID = playbackCommandRequestID
        let expectedIsPlaying = nowPlaying.isPlaying
        let service = mediaService

        playbackCommandTask?.cancel()

        if isMediaStreamActive {
            // 書き込み完了ではなく、stream の状態通知で操作成功を確定する。
            // 通知が欠けた場合だけ readback し、楽観表示のまま固まるのを防ぐ。
            isPlaybackCommandPending = true
            pendingPlaybackTarget = expectedIsPlaying
            lastAdapterEvent?.isPlaying = expectedIsPlaying
            lastAdapterEvent?.timestamp = Date()
            playbackCommandTask = Task { [weak self] in
                await service.togglePlayPause()
                guard let self, self.playbackCommandRequestID == requestID else { return }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled,
                      self.playbackCommandRequestID == requestID,
                      self.isPlaybackCommandPending
                else { return }
                let readback = await service.nowPlaying()
                guard !Task.isCancelled,
                      self.playbackCommandRequestID == requestID,
                      self.isPlaybackCommandPending
                else { return }
                if readback.hasMedia {
                    self.nowPlaying = readback
                }
                self.isPlaybackCommandPending = false
                self.pendingPlaybackTarget = nil
                self.playbackCommandTask = nil
            }
            return
        }

        isPlaybackCommandPending = true
        playbackCommandTask = Task.detached(priority: .userInitiated) { [weak self] in
            await service.togglePlayPause()
            let readback = await Self.readNowPlayingAfterPlaybackToggle(
                service: service,
                expectedIsPlaying: expectedIsPlaying
            )
            await MainActor.run {
                guard let self, self.playbackCommandRequestID == requestID else { return }
                if let readback {
                    self.nowPlaying = readback
                } else {
                    self.nowPlaying.isPlaying = expectedIsPlaying
                }
                self.isPlaybackCommandPending = false
                self.pendingPlaybackTarget = nil
            }
        }
        schedulePendingWatchdog(
            after: 2.5,
            requestID: requestID,
            requestIDPath: \.playbackCommandRequestID,
            pendingPath: \.isPlaybackCommandPending
        )
    }

    func adjustPlaybackRate(by delta: Double) {
        guard nowPlaying.hasMedia, !isPlaybackRateCommandPending else { return }
        let initialRate = nowPlaying.playbackRate
        let target = (nowPlaying.playbackRate + delta).clamped(to: 0.5...3.0)
        let mediaURLString = nowPlaying.mediaURLString
        let preferredTitle = nowPlaying.title
        let service = mediaService
        playbackRateRequestID += 1
        let requestID = playbackRateRequestID
        isPlaybackRateCommandPending = true
        nowPlaying.playbackRate = target

        nowPlayingRefreshTask?.cancel()
        playbackRateCommandTask?.cancel()
        playbackRateCommandTask = Task.detached(priority: .userInitiated) { [weak self] in
            let appliedRate = await service.setPlaybackSpeed(
                target,
                delta: delta,
                mediaURLString: mediaURLString,
                preferredTitle: preferredTitle
            )
            let readback = appliedRate == nil
                ? await Self.readNowPlayingAfterPlaybackRateChange(
                    service: service,
                    initialRate: initialRate,
                    targetRate: target,
                    delta: delta
                )
                : nil
            await MainActor.run {
                guard let self, self.playbackRateRequestID == requestID else { return }
                if let appliedRate {
                    self.nowPlaying.playbackRate = appliedRate
                } else if let readback {
                    self.nowPlaying = readback
                }
                self.isPlaybackRateCommandPending = false
                self.refreshNowPlaying()
            }
        }
        schedulePendingWatchdog(
            after: 4.0,
            requestID: requestID,
            requestIDPath: \.playbackRateRequestID,
            pendingPath: \.isPlaybackRateCommandPending
        )
    }

    private func schedulePendingWatchdog(
        after seconds: TimeInterval,
        requestID: Int,
        requestIDPath: KeyPath<ControlsStore, Int>,
        pendingPath: ReferenceWritableKeyPath<ControlsStore, Bool>
    ) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self,
                  self[keyPath: requestIDPath] == requestID,
                  self[keyPath: pendingPath]
            else { return }
            mediaLog.error("pending watchdog cleared a stuck media command after \(seconds, format: .fixed(precision: 1))s")
            self[keyPath: pendingPath] = false
            self.refreshNowPlaying()
        }
    }

    private func refreshNowPlaying() {
        nowPlayingRefreshTask?.cancel()
        nowPlayingRefreshTask = Task { [weak self] in
            guard let self else { return }
            let nextNowPlaying = await mediaService.nowPlaying()
            guard !Task.isCancelled else { return }
            guard !isPlaybackCommandPending, !isPlaybackRateCommandPending else { return }
            self.nowPlaying = nextNowPlaying
        }
    }

    nonisolated private static func readNowPlayingAfterPlaybackToggle(
        service: MediaRemoteService,
        expectedIsPlaying: Bool
    ) async -> ControlsNowPlayingState? {
        var latestReadback: ControlsNowPlayingState?
        for delay in [150_000_000, 350_000_000, 700_000_000] as [UInt64] {
            guard !Task.isCancelled else { return nil }
            try? await Task.sleep(nanoseconds: delay)
            let state = await service.nowPlaying()
            guard state.hasMedia else { continue }
            latestReadback = state
            if state.isPlaying == expectedIsPlaying {
                break
            }
        }
        return latestReadback
    }

    nonisolated private static func readNowPlayingAfterPlaybackRateChange(
        service: MediaRemoteService,
        initialRate: Double,
        targetRate: Double,
        delta: Double
    ) async -> ControlsNowPlayingState? {
        var latestReadback: ControlsNowPlayingState?
        for delay in [250_000_000, 500_000_000, 800_000_000] as [UInt64] {
            guard !Task.isCancelled else { return nil }
            try? await Task.sleep(nanoseconds: delay)
            let state = await service.nowPlaying()
            guard state.hasMedia else { continue }
            latestReadback = state
            if playbackRateReadbackMatches(
                state.playbackRate,
                initialRate: initialRate,
                targetRate: targetRate,
                delta: delta
            ) {
                break
            }
        }
        return latestReadback
    }

    nonisolated private static func playbackRateReadbackMatches(
        _ readbackRate: Double,
        initialRate: Double,
        targetRate: Double,
        delta: Double
    ) -> Bool {
        if abs(readbackRate - targetRate) <= 0.06 {
            return true
        }
        if delta > 0 {
            return readbackRate > initialRate + 0.05
        }
        if delta < 0 {
            return readbackRate < initialRate - 0.05
        }
        return abs(readbackRate - initialRate) <= 0.05
    }
}

private final class DisplayBrightnessService: @unchecked Sendable {
    static let minimumBrightness = 0.05

    private struct DisplayProbe: Sendable {
        let displayID: CGDirectDisplayID
        let name: String
    }

    private let bridge = DisplayServicesBridge()
    private let ddcBridge = DDCBrightnessBridge()
    private let softwareBridge = DisplaySoftwareBrightnessBridge()

    /// Hardware reads (DDC over I2C in particular) can block for tens of milliseconds,
    /// so they run off the main actor. The software gamma bridge holds main-thread-only
    /// state and is consulted back on the main actor.
    func displays() async -> [ControlsDisplay] {
        let probes = await MainActor.run {
            NSScreen.screens.compactMap { screen -> DisplayProbe? in
                guard let displayID = screen.displayID else { return nil }
                return DisplayProbe(displayID: displayID, name: screen.localizedName)
            }
        }
        let readings = probes.map { probe -> (probe: DisplayProbe, isInternal: Bool, ddcBrightness: Double?, hardwareBrightness: Float?) in
            let isInternal = CGDisplayIsBuiltin(probe.displayID) != 0
            let ddcBrightness = isInternal ? nil : ddcBridge.getBrightness(for: probe.displayID)
            let hardwareBrightness = ddcBrightness == nil ? bridge.getBrightness(for: probe.displayID) : nil
            return (probe, isInternal, ddcBrightness, hardwareBrightness)
        }
        return await MainActor.run {
            readings.map { reading in
                let usesHardwareBrightness = reading.hardwareBrightness != nil && self.bridge.canSetBrightness
                let usesDDCBrightness = reading.ddcBrightness != nil
                let usesSoftwareBrightness = !usesHardwareBrightness && !usesDDCBrightness && !reading.isInternal
                let brightness = usesHardwareBrightness
                    ? Double(reading.hardwareBrightness ?? 1)
                    : (reading.ddcBrightness ?? self.softwareBridge.brightness(for: reading.probe.displayID))

                return ControlsDisplay(
                    id: String(reading.probe.displayID),
                    displayID: reading.probe.displayID,
                    name: reading.probe.name,
                    kind: reading.isInternal ? .internalDisplay : .externalDisplay,
                    brightness: brightness.clamped(to: Self.minimumBrightness...1),
                    isControllable: usesHardwareBrightness || usesDDCBrightness || usesSoftwareBrightness
                )
            }
        }
    }

    func setBrightness(_ brightness: Double, for displayID: CGDirectDisplayID) -> Bool {
        let normalized = brightness.clamped(to: Self.minimumBrightness...1)
        if CGDisplayIsBuiltin(displayID) == 0 {
            if ddcBridge.setBrightness(normalized, for: displayID) {
                return true
            }
            if bridge.setBrightness(Float(normalized), for: displayID) {
                return true
            }
            return softwareBridge.setBrightness(normalized, for: displayID)
        }
        if bridge.setBrightness(Float(normalized), for: displayID) {
            return true
        }
        return false
    }
}

private final class DisplayServicesBridge {
    typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private let getBrightnessFunction: GetBrightness?
    private let setBrightnessFunction: SetBrightness?

    init() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY) else {
            getBrightnessFunction = nil
            setBrightnessFunction = nil
            return
        }
        if let symbol = dlsym(handle, "DisplayServicesGetBrightness") {
            getBrightnessFunction = unsafeBitCast(symbol, to: GetBrightness.self)
        } else {
            getBrightnessFunction = nil
        }
        if let symbol = dlsym(handle, "DisplayServicesSetBrightness") {
            setBrightnessFunction = unsafeBitCast(symbol, to: SetBrightness.self)
        } else {
            setBrightnessFunction = nil
        }
    }

    var canSetBrightness: Bool {
        setBrightnessFunction != nil
    }

    func getBrightness(for displayID: CGDirectDisplayID) -> Float? {
        guard let getBrightnessFunction else { return nil }
        var value: Float = -1
        let result = getBrightnessFunction(displayID, &value)
        guard result == 0, value >= 0 else { return nil }
        return min(max(value, 0), 1)
    }

    func setBrightness(_ value: Float, for displayID: CGDirectDisplayID) -> Bool {
        guard let setBrightnessFunction else { return false }
        return setBrightnessFunction(displayID, min(max(value, 0), 1)) == 0
    }
}

private final class DDCBrightnessBridge: @unchecked Sendable {
    private enum VCPFeature: UInt8 {
        case brightness = 0x10
        case speakerVolume = 0x62
    }

    private struct VCPValue {
        let current: Int
        let max: Int
    }

    private struct DisplayIdentity: Equatable {
        let vendorID: UInt32
        let productID: UInt32
        let serialNumber: UInt32

        func matches(_ other: DisplayIdentity) -> Bool {
            vendorID == other.vendorID
                && productID == other.productID
                && (serialNumber == other.serialNumber || serialNumber == 0 || other.serialNumber == 0)
        }
    }

    private final class DDCDisplay {
        let avService: CFTypeRef
        let identity: DisplayIdentity
        var maxValuesByFeature: [UInt8: Int] = [:]

        init(avService: CFTypeRef, identity: DisplayIdentity) {
            self.avService = avService
            self.identity = identity
        }
    }

    typealias CreateWithService = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias CopyEDID = @convention(c) (CFTypeRef, UnsafeMutablePointer<Unmanaged<CFData>?>) -> kern_return_t
    typealias ReadI2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> kern_return_t
    typealias WriteI2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> kern_return_t

    private let queue = DispatchQueue(label: "local.codex.hover-pocket.ddc-controls")
    private let createWithService: CreateWithService?
    private let copyEDID: CopyEDID?
    private let readI2C: ReadI2C?
    private let writeI2C: WriteI2C?
    private var displaysByID: [CGDirectDisplayID: DDCDisplay] = [:]

    init() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else {
            createWithService = nil
            copyEDID = nil
            readI2C = nil
            writeI2C = nil
            return
        }
        createWithService = dlsym(handle, "IOAVServiceCreateWithService").map {
            unsafeBitCast($0, to: CreateWithService.self)
        }
        copyEDID = dlsym(handle, "IOAVServiceCopyEDID").map {
            unsafeBitCast($0, to: CopyEDID.self)
        }
        readI2C = dlsym(handle, "IOAVServiceReadI2C").map {
            unsafeBitCast($0, to: ReadI2C.self)
        }
        writeI2C = dlsym(handle, "IOAVServiceWriteI2C").map {
            unsafeBitCast($0, to: WriteI2C.self)
        }
    }

    func getBrightness(for displayID: CGDirectDisplayID) -> Double? {
        queue.sync {
            guard let display = ddcDisplay(for: displayID),
                  let value = readValue(.brightness, from: display)
            else {
                return nil
            }
            display.maxValuesByFeature[VCPFeature.brightness.rawValue] = value.max
            guard value.max > 0 else { return nil }
            return Double(value.current).clamped(to: 0...Double(value.max)) / Double(value.max)
        }
    }

    func setBrightness(_ brightness: Double, for displayID: CGDirectDisplayID) -> Bool {
        queue.sync {
            guard let display = ddcDisplay(for: displayID) else { return false }
            let maxBrightness: Int
            if let cachedMax = display.maxValuesByFeature[VCPFeature.brightness.rawValue], cachedMax > 0 {
                maxBrightness = cachedMax
            } else if let value = readValue(.brightness, from: display), value.max > 0 {
                maxBrightness = value.max
                display.maxValuesByFeature[VCPFeature.brightness.rawValue] = value.max
            } else {
                return false
            }
            let rawValue = Int((brightness.clamped(to: DisplayBrightnessService.minimumBrightness...1) * Double(maxBrightness)).rounded())
                .clamped(to: 1...maxBrightness)
            return writeValue(rawValue, feature: .brightness, to: display)
        }
    }

    func getSpeakerVolume() -> Double? {
        queue.sync {
            for displayID in externalDisplayIDs() {
                guard let display = ddcDisplay(for: displayID),
                      let value = readValue(.speakerVolume, from: display),
                      value.max > 0
                else {
                    continue
                }
                display.maxValuesByFeature[VCPFeature.speakerVolume.rawValue] = value.max
                return Double(value.current).clamped(to: 0...Double(value.max)) / Double(value.max)
            }
            return nil
        }
    }

    func setSpeakerVolume(_ volume: Double) -> Bool {
        queue.sync {
            var didSet = false
            for displayID in externalDisplayIDs() {
                guard let display = ddcDisplay(for: displayID) else { continue }
                let maxVolume: Int
                if let cachedMax = display.maxValuesByFeature[VCPFeature.speakerVolume.rawValue], cachedMax > 0 {
                    maxVolume = cachedMax
                } else if let value = readValue(.speakerVolume, from: display), value.max > 0 {
                    maxVolume = value.max
                    display.maxValuesByFeature[VCPFeature.speakerVolume.rawValue] = value.max
                } else {
                    maxVolume = 100
                }
                let rawValue = Int((volume.clamped(to: 0...1) * Double(maxVolume)).rounded())
                    .clamped(to: 0...maxVolume)
                didSet = writeValue(rawValue, feature: .speakerVolume, to: display) || didSet
            }
            return didSet
        }
    }

    func hasAddressableExternalDisplay() -> Bool {
        queue.sync {
            externalDisplayIDs().contains { ddcDisplay(for: $0) != nil }
        }
    }

    private func ddcDisplay(for displayID: CGDirectDisplayID) -> DDCDisplay? {
        if let cached = displaysByID[displayID] {
            return cached
        }
        guard let displayIdentity = displayIdentity(for: displayID) else { return nil }
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("DCPAVServiceProxy"),
            &iterator
        )
        guard result == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            guard service != IO_OBJECT_NULL else { break }
            defer { IOObjectRelease(service) }
            guard isExternalDCPService(service),
                  let avService = createWithService?(kCFAllocatorDefault, service)?.takeRetainedValue(),
                  let edid = copyEDID(from: avService),
                  let identity = Self.identity(from: edid),
                  identity.matches(displayIdentity)
            else {
                continue
            }
            let display = DDCDisplay(avService: avService, identity: identity)
            displaysByID[displayID] = display
            return display
        }
        return nil
    }

    private func displayIdentity(for displayID: CGDirectDisplayID) -> DisplayIdentity? {
        let vendorID = CGDisplayVendorNumber(displayID)
        let productID = CGDisplayModelNumber(displayID)
        let serialNumber = CGDisplaySerialNumber(displayID)
        guard vendorID != 0, productID != 0 else { return nil }
        return DisplayIdentity(vendorID: vendorID, productID: productID, serialNumber: serialNumber)
    }

    private func isExternalDCPService(_ service: io_service_t) -> Bool {
        let location = IORegistryEntrySearchCFProperty(
            service,
            kIOServicePlane,
            "Location" as CFString,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively)
        ) as? String
        return location == "External"
    }

    private func copyEDID(from avService: CFTypeRef) -> Data? {
        guard let copyEDID else { return nil }
        var edidRef: Unmanaged<CFData>?
        let result = copyEDID(avService, &edidRef)
        guard result == KERN_SUCCESS, let edid = edidRef?.takeRetainedValue() else { return nil }
        return edid as Data
    }

    private func externalDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displayIDs, &count) == .success else { return [] }
        return displayIDs.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }
    }

    private func readValue(_ feature: VCPFeature, from display: DDCDisplay) -> VCPValue? {
        guard let readI2C, let writeI2C else { return nil }
        var request: [UInt8] = [0x82, 0x01, feature.rawValue]
        request.append(Self.checksum([0x6E, 0x51] + request))
        let requestSize = UInt32(request.count)
        let writeStatus = request.withUnsafeMutableBytes { pointer in
            writeI2C(display.avService, 0x37, 0x51, pointer.baseAddress!, requestSize)
        }
        guard writeStatus == KERN_SUCCESS else { return nil }
        usleep(50_000)

        var response = [UInt8](repeating: 0, count: 12)
        let responseSize = UInt32(response.count)
        let readStatus = response.withUnsafeMutableBytes { pointer in
            readI2C(display.avService, 0x37, 0x51, pointer.baseAddress!, responseSize)
        }
        guard readStatus == KERN_SUCCESS,
              response.count >= 11,
              response[0] == 0x6E,
              response[1] == 0x88,
              response[2] == 0x02,
              response[3] == 0x00,
              response[4] == feature.rawValue,
              Self.checksum([0x50] + Array(response.prefix(10))) == response[10]
        else {
            return nil
        }
        let maxValue = Int(response[6]) << 8 | Int(response[7])
        let currentValue = Int(response[8]) << 8 | Int(response[9])
        guard maxValue > 0 else { return nil }
        return VCPValue(current: currentValue, max: maxValue)
    }

    private func writeValue(_ value: Int, feature: VCPFeature, to display: DDCDisplay) -> Bool {
        guard let writeI2C else { return false }
        let highByte = UInt8((value >> 8) & 0xFF)
        let lowByte = UInt8(value & 0xFF)
        var request: [UInt8] = [0x84, 0x03, feature.rawValue, highByte, lowByte]
        request.append(Self.checksum([0x6E, 0x51] + request))
        let requestSize = UInt32(request.count)
        let status = request.withUnsafeMutableBytes { pointer in
            writeI2C(display.avService, 0x37, 0x51, pointer.baseAddress!, requestSize)
        }
        return status == KERN_SUCCESS
    }

    private static func identity(from edid: Data) -> DisplayIdentity? {
        guard edid.count >= 16 else { return nil }
        let bytes = [UInt8](edid.prefix(16))
        let manufacturer = UInt32(bytes[8]) << 8 | UInt32(bytes[9])
        let product = UInt32(bytes[10]) | UInt32(bytes[11]) << 8
        let serial = UInt32(bytes[12])
            | UInt32(bytes[13]) << 8
            | UInt32(bytes[14]) << 16
            | UInt32(bytes[15]) << 24
        return DisplayIdentity(vendorID: manufacturer, productID: product, serialNumber: serial)
    }

    private static func checksum(_ bytes: [UInt8]) -> UInt8 {
        bytes.reduce(0, ^)
    }
}

private final class DisplaySoftwareBrightnessBridge {
    private var brightnessByDisplayID: [CGDirectDisplayID: Double] = [:]
    private let tableSize = 256

    func brightness(for displayID: CGDirectDisplayID) -> Double {
        brightnessByDisplayID[displayID] ?? 1
    }

    func setBrightness(_ brightness: Double, for displayID: CGDirectDisplayID) -> Bool {
        let normalized = brightness.clamped(to: DisplayBrightnessService.minimumBrightness...1)
        let capacity = Int(CGDisplayGammaTableCapacity(displayID))
        let sampleCount = min(max(capacity, 2), tableSize)
        var red = [CGGammaValue]()
        var green = [CGGammaValue]()
        var blue = [CGGammaValue]()
        red.reserveCapacity(sampleCount)
        green.reserveCapacity(sampleCount)
        blue.reserveCapacity(sampleCount)

        for index in 0..<sampleCount {
            let base = Float(index) / Float(max(sampleCount - 1, 1))
            let value = CGGammaValue(base * Float(normalized))
            red.append(value)
            green.append(value)
            blue.append(value)
        }

        let result = red.withUnsafeBufferPointer { redPointer in
            green.withUnsafeBufferPointer { greenPointer in
                blue.withUnsafeBufferPointer { bluePointer in
                    guard let redBase = redPointer.baseAddress,
                          let greenBase = greenPointer.baseAddress,
                          let blueBase = bluePointer.baseAddress
                    else {
                        return CGError.failure
                    }
                    return CGSetDisplayTransferByTable(
                        displayID,
                        UInt32(sampleCount),
                        redBase,
                        greenBase,
                        blueBase
                    )
                }
            }
        }
        guard result == .success else { return false }
        brightnessByDisplayID[displayID] = normalized
        return true
    }
}

private final class SystemVolumeService: @unchecked Sendable {
    private let ddcBridge = DDCBrightnessBridge()
    private let monitorVolumeMemoryQueue = DispatchQueue(label: "local.codex.hover-pocket.monitor-volume-memory")
    private var lastAudibleMonitorVolume = 0.5
    private var lastMonitorMuted = false

    func currentState() async -> ControlsVolumeState {
        await Task.detached(priority: .utility) { [self] in
            readCurrentState()
        }.value ?? .empty
    }

    func setVolume(_ level: Double) async {
        let normalized = Float32(level.clamped(to: 0...1))
        await Task.detached(priority: .utility) { [self] in
            let deviceID = Self.defaultOutputDevice()
            let shouldWriteMonitorVolume = deviceID.map { Self.isDisplayAudioOutput(deviceID: $0) } ?? true
            let didSetCoreAudio = Self.setVolume(normalized)
            if normalized > 0 {
                _ = Self.setMuted(false)
            }
            if shouldWriteMonitorVolume || !didSetCoreAudio {
                let didSetMonitor = ddcBridge.setSpeakerVolume(Double(normalized))
                if didSetMonitor, normalized > 0.01 {
                    rememberAudibleMonitorVolume(Double(normalized))
                }
                if didSetMonitor {
                    rememberMonitorMuted(normalized <= 0.005)
                }
            }
        }.value
    }

    func setMuted(_ isMuted: Bool) async {
        await Task.detached(priority: .utility) { [self] in
            let deviceID = Self.defaultOutputDevice()
            let shouldWriteMonitorVolume = deviceID.map { Self.isDisplayAudioOutput(deviceID: $0) } ?? true
            let didSetCoreAudio = Self.setMuted(isMuted)
            guard shouldWriteMonitorVolume || !didSetCoreAudio else { return }

            if isMuted {
                if let currentVolume = ddcBridge.getSpeakerVolume(), currentVolume > 0.01 {
                    rememberAudibleMonitorVolume(currentVolume)
                }
                if ddcBridge.setSpeakerVolume(0) {
                    rememberMonitorMuted(true)
                }
            } else if (ddcBridge.getSpeakerVolume() ?? 0) <= 0.005 {
                if ddcBridge.setSpeakerVolume(rememberedAudibleMonitorVolume()) {
                    rememberMonitorMuted(false)
                }
            } else {
                rememberMonitorMuted(false)
            }
        }.value
    }

    private func readCurrentState() -> ControlsVolumeState? {
        let deviceID = Self.defaultOutputDevice()
        let coreAudioVolume = deviceID.flatMap { Self.readVolume(deviceID: $0) }
        let coreAudioMuted = deviceID.flatMap { Self.readMuted(deviceID: $0) } ?? false
        let shouldReadMonitorVolume = deviceID.map { Self.isDisplayAudioOutput(deviceID: $0) } ?? true
        let canSetCoreAudioVolume = deviceID.map { Self.isVolumeSettable(deviceID: $0) } ?? false

        if shouldReadMonitorVolume || coreAudioVolume == nil || !canSetCoreAudioVolume {
            if let monitorVolume = ddcBridge.getSpeakerVolume() {
                let normalized = monitorVolume.clamped(to: 0...1)
                if normalized > 0.01 {
                    rememberAudibleMonitorVolume(normalized)
                }
                rememberMonitorMuted(normalized <= 0.005)
                return ControlsVolumeState(level: normalized, isMuted: coreAudioMuted || normalized <= 0.005)
            }
            if shouldReadMonitorVolume, ddcBridge.hasAddressableExternalDisplay() {
                let rememberedVolume = rememberedAudibleMonitorVolume()
                return ControlsVolumeState(level: rememberedVolume, isMuted: coreAudioMuted || rememberedMonitorMuted())
            }
        }

        if let coreAudioVolume {
            return ControlsVolumeState(level: Double(coreAudioVolume).clamped(to: 0...1), isMuted: coreAudioMuted)
        }
        return nil
    }

    private func rememberAudibleMonitorVolume(_ volume: Double) {
        let normalized = volume.clamped(to: 0...1)
        guard normalized > 0.01 else { return }
        monitorVolumeMemoryQueue.sync {
            lastAudibleMonitorVolume = normalized
        }
    }

    private func rememberedAudibleMonitorVolume() -> Double {
        monitorVolumeMemoryQueue.sync {
            lastAudibleMonitorVolume
        }
    }

    private func rememberMonitorMuted(_ isMuted: Bool) {
        monitorVolumeMemoryQueue.sync {
            lastMonitorMuted = isMuted
        }
    }

    private func rememberedMonitorMuted() -> Bool {
        monitorVolumeMemoryQueue.sync {
            lastMonitorMuted
        }
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private static func isDisplayAudioOutput(deviceID: AudioDeviceID) -> Bool {
        guard let transportType = transportType(deviceID: deviceID) else { return false }
        return transportType == kAudioDeviceTransportTypeHDMI
            || transportType == kAudioDeviceTransportTypeDisplayPort
    }

    private static func transportType(deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var transportType = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transportType)
        guard status == noErr else { return nil }
        return transportType
    }

    private static func readVolume(deviceID: AudioDeviceID) -> Float32? {
        var address = volumeAddress()
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        guard status == noErr else { return nil }
        return volume.clamped(to: 0...1)
    }

    private static func isVolumeSettable(deviceID: AudioDeviceID) -> Bool {
        var address = volumeAddress()
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    private static func setVolume(_ volume: Float32) -> Bool {
        guard let deviceID = defaultOutputDevice() else { return false }
        var address = volumeAddress()
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr, settable.boolValue else { return false }
        var value = volume.clamped(to: 0...1)
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value) == noErr
    }

    private static func readMuted(deviceID: AudioDeviceID) -> Bool? {
        var address = muteAddress()
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var muted = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted)
        guard status == noErr else { return nil }
        return muted != 0
    }

    private static func setMuted(_ isMuted: Bool) -> Bool {
        guard let deviceID = defaultOutputDevice() else { return false }
        var address = muteAddress()
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr, settable.boolValue else { return false }
        var muted = UInt32(isMuted ? 1 : 0)
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &muted) == noErr
    }

    private static func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}

final class MediaRemoteService: @unchecked Sendable {
    typealias GetNowPlayingInfo = @convention(c) (DispatchQueue, @escaping @convention(block) (NSDictionary?) -> Void) -> Void
    typealias SendCommand = @convention(c) (Int32, CFDictionary?) -> Void
    typealias SetElapsedTime = @convention(c) (Double) -> Void
    typealias SetPlaybackSpeed = @convention(c) (Float) -> Void

    private let getNowPlayingInfo: GetNowPlayingInfo?
    private let sendCommand: SendCommand?
    private let setElapsedTimeFunction: SetElapsedTime?
    private let setPlaybackSpeedFunction: SetPlaybackSpeed?
    private let adapterClient = MediaRemoteAdapterClient()
    private let jxaFallback = JXANowPlayingService()
    private let browserFallback = BrowserNowPlayingService()
    private let playbackRateLock = NSLock()
    private var playbackRateOverride: (rate: Double, expiresAt: Date)?

    init() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY) else {
            getNowPlayingInfo = nil
            sendCommand = nil
            setElapsedTimeFunction = nil
            setPlaybackSpeedFunction = nil
            return
        }
        if let symbol = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") {
            getNowPlayingInfo = unsafeBitCast(symbol, to: GetNowPlayingInfo.self)
        } else {
            getNowPlayingInfo = nil
        }
        if let symbol = dlsym(handle, "MRMediaRemoteSendCommand") {
            sendCommand = unsafeBitCast(symbol, to: SendCommand.self)
        } else {
            sendCommand = nil
        }
        if let symbol = dlsym(handle, "MRMediaRemoteSetElapsedTime") {
            setElapsedTimeFunction = unsafeBitCast(symbol, to: SetElapsedTime.self)
        } else {
            setElapsedTimeFunction = nil
        }
        if let symbol = dlsym(handle, "MRMediaRemoteSetPlaybackSpeed") {
            setPlaybackSpeedFunction = unsafeBitCast(symbol, to: SetPlaybackSpeed.self)
        } else {
            setPlaybackSpeedFunction = nil
        }
    }

    var isAdapterAvailable: Bool {
        adapterClient.isAvailable
    }

    func startNowPlayingStream(onEvent: @escaping @Sendable (AdapterNowPlaying?) -> Void) {
        adapterClient.startListening(onEvent: onEvent)
    }

    func stopNowPlayingStream() {
        adapterClient.stopListening()
    }

    /// ブラウザ由来のメタデータ（URL・プレビュー windowID・実 playbackRate）で状態を補強する
    func enrich(_ baseState: ControlsNowPlayingState) async -> ControlsNowPlayingState {
        let context = await browserFallback.context(preferredTitle: baseState.title)
        return state(baseState, enrichedWith: context)
    }

    static func state(fromAdapter adapterState: AdapterNowPlaying) -> ControlsNowPlayingState {
        let sourceName: String
        if !adapterState.artist.isEmpty {
            sourceName = adapterState.artist
        } else if !adapterState.album.isEmpty {
            sourceName = adapterState.album
        } else if !adapterState.applicationName.isEmpty {
            sourceName = adapterState.applicationName
        } else {
            sourceName = "Media"
        }
        let duration = max(adapterState.duration, adapterState.elapsed, 0)
        let progress = adapterState.extrapolatedElapsed
        return ControlsNowPlayingState(
            title: adapterState.title,
            sourceName: sourceName,
            hasMedia: true,
            artworkData: adapterState.artworkData,
            mediaURLString: nil,
            previewWindowID: nil,
            progress: progress.clamped(to: 0...max(duration, progress)),
            duration: duration,
            isPlaying: adapterState.isPlaying,
            playbackRate: (adapterState.playbackRate > 0 ? adapterState.playbackRate : 1).clamped(to: 0.5...3.0)
        )
    }

    func nowPlaying() async -> ControlsNowPlayingState {
        if let adapterState = await adapterClient.fetchNowPlaying() {
            let baseState = Self.state(fromAdapter: adapterState)
            let context = await browserFallback.context(preferredTitle: baseState.title)
            return state(baseState, enrichedWith: context)
        }

        let jxaState = await jxaFallback.nowPlaying()
        if jxaState.hasMedia {
            let context = await browserFallback.context(preferredTitle: jxaState.title)
            return state(jxaState, enrichedWith: context)
        }

        let remoteState = await mediaRemoteNowPlaying()
        if remoteState.hasMedia {
            let context = await browserFallback.context(preferredTitle: remoteState.title)
            return state(remoteState, enrichedWith: context)
        }
        let context = await browserFallback.context()
        if let context {
            return state(BrowserNowPlayingService.state(from: context), enrichedWith: context)
        }
        return state(remoteState, enrichedWith: nil)
    }

    private func mediaRemoteNowPlaying() async -> ControlsNowPlayingState {
        guard let getNowPlayingInfo else { return .empty }
        return await withCheckedContinuation { continuation in
            getNowPlayingInfo(DispatchQueue.global(qos: .utility)) { info in
                continuation.resume(returning: Self.parseNowPlaying(info))
            }
        }
    }

    func togglePlayPause() async {
        if await adapterClient.togglePlayPause() {
            return
        }
        // macOS 15.4 未満などで adapter が使えない場合のみ直接呼ぶ
        sendCommand?(2, nil)
    }

    func nextTrack() async {
        if await adapterClient.nextTrack() {
            return
        }
        sendCommand?(4, nil)
    }

    func previousTrack() async {
        if await adapterClient.previousTrack() {
            return
        }
        sendCommand?(5, nil)
    }

    func setElapsedTime(_ elapsedTime: TimeInterval) async {
        let target = max(0, elapsedTime)
        if await adapterClient.setElapsedTime(target) {
            return
        }
        setElapsedTimeFunction?(target)
        sendCommand?(24, [
            "kMRMediaRemoteOptionPlaybackPosition": target
        ] as CFDictionary)
    }

    @discardableResult
    func setPlaybackSpeed(
        _ speed: Double,
        delta: Double = 0,
        mediaURLString: String? = nil,
        preferredTitle: String = ""
    ) async -> Double? {
        let target = speed.clamped(to: 0.5...3.0)
        let browserRate = await browserFallback.setPlaybackSpeed(
            target,
            delta: delta,
            mediaURLString: mediaURLString,
            preferredTitle: preferredTitle
        )
        if let browserRate {
            setPlaybackRateOverride(browserRate)
            return browserRate
        }
        setPlaybackSpeedFunction?(Float(target))
        sendCommand?(19, [
            "kMRMediaRemoteOptionPlaybackRate": target
        ] as CFDictionary)
        return nil
    }

    private func state(_ state: ControlsNowPlayingState, enrichedWith context: BrowserMediaContext?) -> ControlsNowPlayingState {
        var enriched = state
        if let context {
            if enriched.title.isEmpty {
                enriched.title = context.cleanedTitle
            }
            if enriched.sourceName.isEmpty || enriched.sourceName == "Media" {
                enriched.sourceName = context.sourceName
            }
            enriched.mediaURLString = context.urlString
            enriched.previewWindowID = context.windowID
            if let contextPlaybackRate = context.playbackRate, contextPlaybackRate > 0 {
                enriched.playbackRate = contextPlaybackRate.clamped(to: 0.5...3.0)
            }
        }
        if let override = playbackRateOverrideValue() {
            enriched.playbackRate = override
        }
        return enriched
    }

    private func setPlaybackRateOverride(_ rate: Double) {
        playbackRateLock.lock()
        playbackRateOverride = (rate, Date().addingTimeInterval(6.0))
        playbackRateLock.unlock()
    }

    private func playbackRateOverrideValue() -> Double? {
        playbackRateLock.lock()
        defer { playbackRateLock.unlock() }
        guard let playbackRateOverride else { return nil }
        guard playbackRateOverride.expiresAt > Date() else {
            self.playbackRateOverride = nil
            return nil
        }
        return playbackRateOverride.rate
    }

    private static func parseNowPlaying(_ info: NSDictionary?) -> ControlsNowPlayingState {
        guard let info else { return .empty }
        let title = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
        let artist = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
        let album = info["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? ""
        let duration = (info["kMRMediaRemoteNowPlayingInfoDuration"] as? NSNumber)?.doubleValue ?? 0
        let elapsed = (info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? NSNumber)?.doubleValue ?? 0
        let playbackRate = (info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0
        let defaultPlaybackRate = (info["kMRMediaRemoteNowPlayingInfoDefaultPlaybackRate"] as? NSNumber)?.doubleValue ?? 1
        let artworkData = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data
        let contentIdentifiers = [
            "kMRMediaRemoteNowPlayingInfoContentItemIdentifier",
            "kMRMediaRemoteNowPlayingInfoUniqueIdentifier",
            "kMRMediaRemoteNowPlayingInfoRadioStationIdentifier",
            "kMRMediaRemoteNowPlayingInfoiTunesStoreIdentifier"
        ]
        let hasContentIdentifier = contentIdentifiers.contains { key in
            guard let value = info[key] else { return false }
            if let stringValue = value as? String {
                return !stringValue.isEmpty
            }
            return true
        }
        let hasPlaybackSignal = info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] != nil
            || info["kMRMediaRemoteNowPlayingInfoElapsedTime"] != nil
            || info["kMRMediaRemoteNowPlayingInfoTimestamp"] != nil
        let hasMedia = !title.isEmpty
            || !artist.isEmpty
            || !album.isEmpty
            || duration > 0
            || elapsed > 0
            || artworkData != nil
            || hasContentIdentifier
            || hasPlaybackSignal
        let sourceName: String
        if !artist.isEmpty {
            sourceName = artist
        } else if !album.isEmpty {
            sourceName = album
        } else {
            sourceName = hasMedia ? "Media" : ""
        }

        return ControlsNowPlayingState(
            title: title,
            sourceName: sourceName,
            hasMedia: hasMedia,
            artworkData: artworkData,
            mediaURLString: nil,
            previewWindowID: nil,
            progress: elapsed.clamped(to: 0...max(duration, elapsed, 0)),
            duration: max(duration, elapsed, 0),
            isPlaying: playbackRate > 0,
            playbackRate: (playbackRate > 0 ? playbackRate : defaultPlaybackRate).clamped(to: 0.5...3.0)
        )
    }
}

private final class JXANowPlayingService: @unchecked Sendable {
    private struct Payload: Decodable {
        let title: String
        let artist: String
        let album: String
        let duration: Double
        let elapsed: Double
        let playbackRate: Double
        let defaultPlaybackRate: Double
        let sourceName: String
    }

    private static let script = """
    ObjC.import('Foundation');
    $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/').load;
    const request = $.NSClassFromString('MRNowPlayingRequest');
    const item = request ? request.localNowPlayingItem : null;
    const info = item ? item.nowPlayingInfo : null;
    const path = request ? request.localNowPlayingPlayerPath : null;
    function unwrap(value) {
      if (!value) return null;
      const unwrapped = ObjC.unwrap(value);
      return unwrapped === undefined ? null : unwrapped;
    }
    function s(key) {
      if (!info) return '';
      const value = unwrap(info.valueForKey(key));
      return value === null ? '' : String(value);
    }
    function n(key) {
      if (!info) return 0;
      const value = unwrap(info.valueForKey(key));
      const number = Number(value);
      return Number.isFinite(number) ? number : 0;
    }
    const client = path ? path.client : null;
    const displayName = client ? unwrap(client.displayName) : '';
    JSON.stringify({
      title: s('kMRMediaRemoteNowPlayingInfoTitle'),
      artist: s('kMRMediaRemoteNowPlayingInfoArtist'),
      album: s('kMRMediaRemoteNowPlayingInfoAlbum'),
      duration: n('kMRMediaRemoteNowPlayingInfoDuration'),
      elapsed: n('kMRMediaRemoteNowPlayingInfoElapsedTime'),
      playbackRate: n('kMRMediaRemoteNowPlayingInfoPlaybackRate'),
      defaultPlaybackRate: n('kMRMediaRemoteNowPlayingInfoDefaultPlaybackRate'),
      sourceName: displayName ? String(displayName) : ''
    })
    """

    func nowPlaying() async -> ControlsNowPlayingState {
        guard let payload = await Self.fetchPayload() else { return .empty }
        return Self.state(from: payload)
    }

    private static func fetchPayload() async -> Payload? {
        guard let output = await OSAScriptRunner.run(
            arguments: ["-l", "JavaScript", "-e", script],
            timeout: 2.0
        ) else {
            return nil
        }
        guard let data = output.data(using: .utf8), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }

    private static func state(from payload: Payload) -> ControlsNowPlayingState {
        let duration = max(payload.duration, payload.elapsed, 0)
        let playbackRate = payload.playbackRate > 0
            ? payload.playbackRate
            : (payload.defaultPlaybackRate > 0 ? payload.defaultPlaybackRate : 1)
        let hasMedia = !payload.title.isEmpty
            || !payload.artist.isEmpty
            || !payload.album.isEmpty
            || duration > 0
        let sourceName: String
        if !payload.artist.isEmpty {
            sourceName = payload.artist
        } else if !payload.album.isEmpty {
            sourceName = payload.album
        } else if !payload.sourceName.isEmpty {
            sourceName = payload.sourceName
        } else {
            sourceName = hasMedia ? "Media" : ""
        }
        return ControlsNowPlayingState(
            title: payload.title,
            sourceName: sourceName,
            hasMedia: hasMedia,
            artworkData: nil,
            mediaURLString: nil,
            previewWindowID: nil,
            progress: payload.elapsed.clamped(to: 0...duration),
            duration: duration,
            isPlaying: payload.playbackRate > 0,
            playbackRate: playbackRate.clamped(to: 0.5...3.0)
        )
    }
}

private struct BrowserMediaContext: Sendable {
    let processIdentifier: pid_t
    let title: String
    let cleanedTitle: String
    let sourceName: String
    let urlString: String
    let windowID: UInt32?
    let playbackRate: Double?
}

private final class BrowserNowPlayingService: @unchecked Sendable {
    private struct BrowserTarget {
        let bundleIdentifier: String
        let appleScriptName: String
        let scriptKind: ScriptKind
        let usesFocusCommand: Bool

        init(
            bundleIdentifier: String,
            appleScriptName: String,
            scriptKind: ScriptKind,
            usesFocusCommand: Bool = false
        ) {
            self.bundleIdentifier = bundleIdentifier
            self.appleScriptName = appleScriptName
            self.scriptKind = scriptKind
            self.usesFocusCommand = usesFocusCommand
        }
    }

    private enum ScriptKind {
        case chromium
        case safari
    }

    private let targets: [BrowserTarget] = [
        BrowserTarget(bundleIdentifier: "com.google.Chrome", appleScriptName: "Google Chrome", scriptKind: .chromium),
        BrowserTarget(bundleIdentifier: "com.apple.Safari", appleScriptName: "Safari", scriptKind: .safari),
        BrowserTarget(bundleIdentifier: "com.microsoft.edgemac", appleScriptName: "Microsoft Edge", scriptKind: .chromium),
        BrowserTarget(bundleIdentifier: "company.thebrowser.Browser", appleScriptName: "Arc", scriptKind: .chromium),
        BrowserTarget(bundleIdentifier: "company.thebrowser.dia", appleScriptName: "Dia", scriptKind: .chromium, usesFocusCommand: true)
    ]

    private struct CachedTabContext {
        let bundleIdentifier: String
        let urlString: String
        let timestamp: Date
    }

    private static let cacheLifetime: TimeInterval = 10
    private let cacheLock = NSLock()
    private var cachedTabContext: CachedTabContext?

    func context(preferredTitle: String = "") async -> BrowserMediaContext? {
        if let cachedContext = await contextFromCache(preferredTitle: preferredTitle) {
            return cachedContext
        }
        for target in targets {
            guard let application = Self.runningApplication(bundleIdentifier: target.bundleIdentifier),
                  let tab = await Self.bestVisibleMediaTab(
                    in: target,
                    processIdentifier: application.processIdentifier,
                    preferredTitle: preferredTitle
                  )
            else { continue }
            let cleanedTitle = Self.cleanedTitle(tab.title, sourceName: tab.sourceName)
            let playbackRate = target.usesFocusCommand
                ? nil
                : await Self.readPlaybackRate(in: target, matchingURLString: tab.url.absoluteString)
            storeCache(bundleIdentifier: target.bundleIdentifier, urlString: tab.url.absoluteString)
            return BrowserMediaContext(
                processIdentifier: application.processIdentifier,
                title: tab.title,
                cleanedTitle: cleanedTitle,
                sourceName: tab.sourceName,
                urlString: tab.url.absoluteString,
                windowID: tab.windowID,
                playbackRate: playbackRate
            )
        }
        invalidateCache()
        return nil
    }

    private func contextFromCache(preferredTitle: String) async -> BrowserMediaContext? {
        guard let cached = currentCache(),
              let target = targets.first(where: { $0.bundleIdentifier == cached.bundleIdentifier })
        else { return nil }
        guard let application = Self.runningApplication(bundleIdentifier: cached.bundleIdentifier) else {
            invalidateCache()
            return nil
        }
        guard let tab = await Self.tabInfo(in: target, matchingURLString: cached.urlString),
              let mediaSource = Self.sourceName(for: tab.url)
        else {
            invalidateCache()
            return nil
        }
        let normalizedPreferredTitle = Self.cleanedComparableTitle(preferredTitle)
        if !normalizedPreferredTitle.isEmpty {
            let normalizedTabTitle = Self.cleanedComparableTitle(tab.title)
            let matches = normalizedTabTitle.localizedCaseInsensitiveContains(normalizedPreferredTitle)
                || normalizedPreferredTitle.localizedCaseInsensitiveContains(normalizedTabTitle)
            guard matches else { return nil }
        }
        let cleanedTitle = Self.cleanedTitle(tab.title, sourceName: mediaSource)
        let playbackRate = target.usesFocusCommand
            ? nil
            : await Self.readPlaybackRate(in: target, matchingURLString: tab.url.absoluteString)
        storeCache(bundleIdentifier: target.bundleIdentifier, urlString: tab.url.absoluteString)
        return BrowserMediaContext(
            processIdentifier: application.processIdentifier,
            title: tab.title,
            cleanedTitle: cleanedTitle,
            sourceName: mediaSource,
            urlString: tab.url.absoluteString,
            windowID: Self.windowID(
                for: application.processIdentifier,
                title: tab.title,
                cleanedTitle: cleanedTitle
            ),
            playbackRate: playbackRate
        )
    }

    private func currentCache() -> CachedTabContext? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let cachedTabContext else { return nil }
        guard Date().timeIntervalSince(cachedTabContext.timestamp) < Self.cacheLifetime else {
            self.cachedTabContext = nil
            return nil
        }
        return cachedTabContext
    }

    private func storeCache(bundleIdentifier: String, urlString: String) {
        cacheLock.lock()
        cachedTabContext = CachedTabContext(
            bundleIdentifier: bundleIdentifier,
            urlString: urlString,
            timestamp: Date()
        )
        cacheLock.unlock()
    }

    private func invalidateCache() {
        cacheLock.lock()
        cachedTabContext = nil
        cacheLock.unlock()
    }

    static func state(from context: BrowserMediaContext) -> ControlsNowPlayingState {
        ControlsNowPlayingState(
            title: context.cleanedTitle,
            sourceName: context.sourceName,
            hasMedia: true,
            artworkData: nil,
            mediaURLString: context.urlString,
            previewWindowID: context.windowID,
            progress: 0,
            duration: 0,
            isPlaying: false,
            playbackRate: (context.playbackRate ?? 1).clamped(to: 0.5...3.0)
        )
    }

    @discardableResult
    func setPlaybackSpeed(
        _ speed: Double,
        delta: Double,
        mediaURLString: String?,
        preferredTitle: String
    ) async -> Double? {
        let targetSpeed = speed.clamped(to: 0.5...3.0)
        for target in targets {
            guard let application = Self.runningApplication(bundleIdentifier: target.bundleIdentifier),
                  let tab = await Self.selectedMediaTab(
                    in: target,
                    preferredURLString: mediaURLString,
                    preferredTitle: preferredTitle
                  )
            else { continue }
            let tabURLString = tab.url.absoluteString
            if !target.usesFocusCommand,
               let appliedRate = await Self.setHTMLPlaybackSpeed(targetSpeed, in: target, matchingURLString: tabURLString) {
                return appliedRate
            }
            if delta != 0,
               await Self.focusTab(in: target, matchingURLString: tabURLString) {
                try? await Task.sleep(nanoseconds: UInt64((target.usesFocusCommand ? 0.24 : 0.12) * 1_000_000_000))
                guard Self.postPlaybackRateShortcut(delta: delta, processIdentifier: application.processIdentifier) else {
                    continue
                }
                try? await Task.sleep(nanoseconds: UInt64((target.usesFocusCommand ? 0.32 : 0.25) * 1_000_000_000))
                if target.usesFocusCommand {
                    return Self.nextShortcutPlaybackRate(currentRate: targetSpeed - delta, delta: delta)
                }
                if let shortcutRate = await Self.readPlaybackRate(in: target, matchingURLString: tabURLString),
                   abs(shortcutRate - targetSpeed) < 0.05 {
                    return shortcutRate
                }
            }
        }
        return nil
    }

    private static func runningApplication(bundleIdentifier: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { application in
            application.bundleIdentifier == bundleIdentifier && !application.isTerminated
        }
    }

    private static func bestVisibleMediaTab(in target: BrowserTarget, processIdentifier: pid_t, preferredTitle: String = "") async -> (title: String, url: URL, sourceName: String, windowID: UInt32?)? {
        let tabs = await mediaTabs(in: target).map { tab in
            let cleanedTitle = cleanedTitle(tab.title, sourceName: tab.sourceName)
            return (
                title: tab.title,
                url: tab.url,
                sourceName: tab.sourceName,
                windowID: windowID(for: processIdentifier, title: tab.title, cleanedTitle: cleanedTitle)
            )
        }
        let normalizedPreferredTitle = cleanedComparableTitle(preferredTitle)
        if !normalizedPreferredTitle.isEmpty,
           let matchingTab = tabs.first(where: { tab in
            let normalizedTabTitle = cleanedComparableTitle(tab.title)
            return normalizedTabTitle.localizedCaseInsensitiveContains(normalizedPreferredTitle)
                || normalizedPreferredTitle.localizedCaseInsensitiveContains(normalizedTabTitle)
           }) {
            return matchingTab
        }
        return tabs.first(where: { $0.windowID != nil }) ?? tabs.first
    }

    private static func selectedMediaTab(
        in target: BrowserTarget,
        preferredURLString: String?,
        preferredTitle: String
    ) async -> (title: String, url: URL, sourceName: String)? {
        let tabs = await mediaTabs(in: target)
        let normalizedPreferredURL = preferredURLString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedPreferredTitle = cleanedComparableTitle(preferredTitle)
        let hasPreferredTarget = !normalizedPreferredURL.isEmpty || !normalizedPreferredTitle.isEmpty

        if !normalizedPreferredURL.isEmpty,
           let matchingURLTab = tabs.first(where: { $0.url.absoluteString == normalizedPreferredURL }) {
            return matchingURLTab
        }

        if !normalizedPreferredTitle.isEmpty,
           let matchingTitleTab = tabs.first(where: { tab in
            let normalizedTabTitle = cleanedComparableTitle(tab.title)
            return normalizedTabTitle.localizedCaseInsensitiveContains(normalizedPreferredTitle)
                || normalizedPreferredTitle.localizedCaseInsensitiveContains(normalizedTabTitle)
           }) {
            return matchingTitleTab
        }

        guard !hasPreferredTarget else { return nil }
        return tabs.first
    }

    private static func mediaTabs(in target: BrowserTarget) async -> [(title: String, url: URL, sourceName: String)] {
        guard let result = await runAppleScript(source: scriptSource(for: target)),
              !result.isEmpty
        else {
            return []
        }
        return parseTabResults(result).compactMap { tab in
            guard let mediaSource = sourceName(for: tab.url) else { return nil }
            return (tab.title, tab.url, mediaSource)
        }
    }

    private static func scriptSource(for target: BrowserTarget) -> String {
        let escapedName = target.appleScriptName.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        switch target.scriptKind {
        case .chromium:
            return """
            tell application "\(escapedName)"
              if (count of windows) is 0 then return ""
              set tabOutput to ""
              repeat with browserWindow in windows
                repeat with browserTab in tabs of browserWindow
                  set tabTitle to title of browserTab
                  set tabURL to URL of browserTab
                  if tabURL is not "" then
                    set tabOutput to tabOutput & tabTitle & linefeed & tabURL & linefeed & "---HOVERPOCKET-TAB---" & linefeed
                  end if
                end repeat
              end repeat
              return tabOutput
            end tell
            """
        case .safari:
            return """
            tell application "\(escapedName)"
              if (count of windows) is 0 then return ""
              set tabOutput to ""
              repeat with browserWindow in windows
                repeat with browserTab in tabs of browserWindow
                  set tabTitle to name of browserTab
                  set tabURL to URL of browserTab
                  if tabURL is not "" then
                    set tabOutput to tabOutput & tabTitle & linefeed & tabURL & linefeed & "---HOVERPOCKET-TAB---" & linefeed
                  end if
                end repeat
              end repeat
              return tabOutput
            end tell
            """
        }
    }

    private static func runAppleScript(source: String) async -> String? {
        await runAppleScriptWithTimeout(source: source, timeout: 1.2)
    }

    private static func tabInfo(in target: BrowserTarget, matchingURLString: String) async -> (title: String, url: URL)? {
        guard !matchingURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let result = await runAppleScriptWithTimeout(
            source: tabInfoSource(for: target, matchingURLString: matchingURLString),
            timeout: 0.8
        ) else {
            return nil
        }
        let lines = result.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2, let url = URL(string: lines[1]) else { return nil }
        return (lines[0], url)
    }

    private static func tabInfoSource(for target: BrowserTarget, matchingURLString: String) -> String {
        let escapedName = appleScriptEscaped(target.appleScriptName)
        let escapedURL = appleScriptEscaped(matchingURLString)
        let titleProperty = target.scriptKind == .safari ? "name" : "title"
        return """
        tell application "\(escapedName)"
          if (count of windows) is 0 then return ""
          repeat with browserWindow in windows
            repeat with browserTab in tabs of browserWindow
              set tabURL to URL of browserTab
              if tabURL is "\(escapedURL)" then
                return (\(titleProperty) of browserTab) & linefeed & tabURL
              end if
            end repeat
          end repeat
          return ""
        end tell
        """
    }

    private static func parseTabResults(_ result: String) -> [(title: String, url: URL)] {
        result.components(separatedBy: "---HOVERPOCKET-TAB---").compactMap { entry in
            let lines = entry.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard lines.count >= 2 else { return nil }
            let title = lines[0]
            let urlString = lines[1]
            guard !title.isEmpty, let url = URL(string: urlString) else { return nil }
            return (title, url)
        }
    }

    private static func readPlaybackRate(in target: BrowserTarget, matchingURLString: String) async -> Double? {
        let javascript = """
        (() => {
          const videos = Array.from(document.querySelectorAll('video'));
          const video = videos.find((item) => !item.paused || item.currentTime > 0) || videos[0];
          return video ? String(video.playbackRate || 1) : '';
        })()
        """
        guard let result = await runAppleScriptWithTimeout(
            source: browserJavaScriptSource(for: target, javascript: javascript, matchingURLString: matchingURLString),
            timeout: 0.8
        ) else {
            return nil
        }
        return Double(result)
    }

    private static func setHTMLPlaybackSpeed(_ speed: Double, in target: BrowserTarget, matchingURLString: String) async -> Double? {
        let javascript = """
        (() => {
          const videos = Array.from(document.querySelectorAll('video'));
          const video = videos.find((item) => !item.paused || item.currentTime > 0) || videos[0];
          if (!video) return '';
          video.playbackRate = \(String(format: "%.1f", speed));
          return String(video.playbackRate || \(String(format: "%.1f", speed)));
        })()
        """
        guard let result = await runAppleScriptWithTimeout(
            source: browserJavaScriptSource(for: target, javascript: javascript, matchingURLString: matchingURLString),
            timeout: 0.8
        ) else {
            return nil
        }
        return Double(result)
    }

    private static func browserJavaScriptSource(for target: BrowserTarget, javascript: String, matchingURLString: String? = nil) -> String {
        let escapedName = target.appleScriptName.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedJavaScript = javascript.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        let predicate = tabURLPredicateAppleScript(matchingURLString: matchingURLString)
        switch target.scriptKind {
        case .chromium:
            return """
            tell application "\(escapedName)"
              if (count of windows) is 0 then return ""
              repeat with browserWindow in windows
                repeat with browserTab in tabs of browserWindow
                  set tabURL to URL of browserTab
                  if \(predicate) then
                    try
                      return execute browserTab javascript "\(escapedJavaScript)"
                    end try
                  end if
                end repeat
              end repeat
              return ""
            end tell
            """
        case .safari:
            return """
            tell application "\(escapedName)"
              if (count of windows) is 0 then return ""
              repeat with browserWindow in windows
                repeat with browserTab in tabs of browserWindow
                  set tabURL to URL of browserTab
                  if \(predicate) then
                    try
                      return do JavaScript "\(escapedJavaScript)" in browserTab
                    end try
                  end if
                end repeat
              end repeat
              return ""
            end tell
            """
        }
    }

    private static var mediaURLPredicateAppleScript: String {
        """
        tabURL contains "youtube.com" or tabURL contains "youtu.be" or tabURL contains "music.youtube.com" or tabURL contains "netflix.com" or tabURL contains "twitch.tv" or tabURL contains "vimeo.com"
        """
    }

    private static func tabURLPredicateAppleScript(matchingURLString: String?) -> String {
        guard let matchingURLString,
              !matchingURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return mediaURLPredicateAppleScript
        }
        return "tabURL is \"\(appleScriptEscaped(matchingURLString))\""
    }

    private static func focusTab(in target: BrowserTarget, matchingURLString: String) async -> Bool {
        guard !matchingURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return await runAppleScriptWithTimeout(
            source: focusTabSource(for: target, matchingURLString: matchingURLString),
            timeout: 0.6
        ) == "ok"
    }

    private static func focusTabSource(for target: BrowserTarget, matchingURLString: String) -> String {
        let escapedName = appleScriptEscaped(target.appleScriptName)
        let escapedURL = appleScriptEscaped(matchingURLString)
        switch target.scriptKind {
        case .chromium:
            if target.usesFocusCommand {
                return """
                tell application "\(escapedName)"
                  if (count of windows) is 0 then return ""
                  repeat with browserWindow in windows
                    repeat with browserTab in tabs of browserWindow
                      if URL of browserTab is "\(escapedURL)" then
                        focus browserTab
                        activate
                        return "ok"
                      end if
                    end repeat
                  end repeat
                  return ""
                end tell
                """
            }
            return """
            tell application "\(escapedName)"
              if (count of windows) is 0 then return ""
              repeat with windowIndex from 1 to count of windows
                set browserWindow to window windowIndex
                repeat with tabIndex from 1 to count of tabs of browserWindow
                  set browserTab to tab tabIndex of browserWindow
                  if URL of browserTab is "\(escapedURL)" then
                    set active tab index of browserWindow to tabIndex
                    set index of browserWindow to 1
                    activate
                    return "ok"
                  end if
                end repeat
              end repeat
              return ""
            end tell
            """
        case .safari:
            return """
            tell application "\(escapedName)"
              if (count of windows) is 0 then return ""
              repeat with windowIndex from 1 to count of windows
                set browserWindow to window windowIndex
                repeat with browserTab in tabs of browserWindow
                  if URL of browserTab is "\(escapedURL)" then
                    set current tab of browserWindow to browserTab
                    set index of browserWindow to 1
                    activate
                    return "ok"
                  end if
                end repeat
              end repeat
              return ""
            end tell
            """
        }
    }

    private static func appleScriptEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func runAppleScriptWithTimeout(source: String, timeout: TimeInterval = 2.0) async -> String? {
        await OSAScriptRunner.run(arguments: ["-e", source], timeout: timeout)
    }

    private static func windowID(for processIdentifier: pid_t, title: String, cleanedTitle: String) -> UInt32? {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let candidates = windowList.compactMap { info -> (id: UInt32, area: CGFloat, score: Int)? in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == processIdentifier,
                  let number = info[kCGWindowNumber as String] as? UInt32,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = bounds["Width"],
                  let height = bounds["Height"],
                  width > 120,
                  height > 90
            else {
                return nil
            }
            let name = (info[kCGWindowName as String] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let titleMatches = !name.isEmpty
                && (name.localizedCaseInsensitiveContains(title)
                    || title.localizedCaseInsensitiveContains(name)
                    || name.localizedCaseInsensitiveContains(cleanedTitle)
                    || cleanedTitle.localizedCaseInsensitiveContains(name))
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { return nil }
            let score = titleMatches ? 2 : (name.isEmpty ? 1 : 0)
            return (number, width * height, score)
        }
        return candidates.max { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score < rhs.score
            }
            return lhs.area < rhs.area
        }?.id
    }

    private static func nextShortcutPlaybackRate(currentRate: Double, delta: Double) -> Double {
        let rates = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
        let normalized = currentRate.clamped(to: 0.5...2.0)
        if delta > 0 {
            return rates.first(where: { $0 > normalized + 0.01 }) ?? rates.last ?? 2.0
        }
        if delta < 0 {
            return rates.reversed().first(where: { $0 < normalized - 0.01 }) ?? rates.first ?? 0.5
        }
        return normalized
    }

    private static func postPlaybackRateShortcut(delta: Double, processIdentifier: pid_t) -> Bool {
        let keyCode: CGKeyCode = delta > 0 ? 47 : 43
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            return false
        }
        keyDown.flags = .maskShift
        keyUp.flags = .maskShift
        keyDown.postToPid(processIdentifier)
        keyUp.postToPid(processIdentifier)
        return true
    }

    private static func sourceName(for url: URL) -> String? {
        let host = url.host(percentEncoded: false)?.lowercased() ?? ""
        let path = url.path(percentEncoded: false).lowercased()
        let query = url.query(percentEncoded: false)?.lowercased() ?? ""
        let isYouTubeVideo = host == "youtu.be"
            || path.hasPrefix("/shorts/")
            || path.hasPrefix("/embed/")
            || path.hasPrefix("/live/")
            || (path == "/watch" && query.contains("v="))
        if (host == "youtu.be" || host.hasSuffix(".youtube.com") || host == "youtube.com"), isYouTubeVideo {
            return host == "music.youtube.com" ? "YouTube Music" : "YouTube"
        }
        if host.hasSuffix(".netflix.com") || host == "netflix.com" {
            return "Netflix"
        }
        if host.hasSuffix(".twitch.tv") || host == "twitch.tv" {
            return "Twitch"
        }
        if host.hasSuffix(".vimeo.com") || host == "vimeo.com" {
            return "Vimeo"
        }
        return nil
    }

    private static func cleanedTitle(_ title: String, sourceName: String) -> String {
        var cleaned = title
        for suffix in [" - \(sourceName)", " | \(sourceName)"] where cleaned.hasSuffix(suffix) {
            cleaned.removeLast(suffix.count)
            break
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanedComparableTitle(_ title: String) -> String {
        var cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [" - YouTube", " | YouTube", " - YouTube Music", " | YouTube Music"] where cleaned.hasSuffix(suffix) {
            cleaned.removeLast(suffix.count)
            break
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum OSAScriptRunner {
    static func run(arguments: [String], timeout: TimeInterval) async -> String? {
        let execution = OSAScriptExecution(arguments: arguments)
        return await withCheckedContinuation { continuation in
            execution.start { output in
                continuation.resume(returning: output)
            }
            Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if execution.timeOut() {
                    mediaLog.error("osascript timed out after \(timeout, format: .fixed(precision: 1))s")
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

private final class OSAScriptExecution: @unchecked Sendable {
    private let process = Process()
    private let outputPipe = Pipe()
    private let lock = NSLock()
    private var isResumed = false

    init(arguments: [String]) {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = Pipe()
    }

    func start(onCompletion: @escaping @Sendable (String?) -> Void) {
        process.terminationHandler = { [weak self] finished in
            guard let self, self.tryClaimResume() else { return }
            guard finished.terminationStatus == 0 else {
                mediaLog.debug("osascript exited with status \(finished.terminationStatus)")
                onCompletion(nil)
                return
            }
            let data = self.outputPipe.fileHandleForReading.readDataToEndOfFile()
            let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            onCompletion(value?.isEmpty == false ? value : nil)
        }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            if tryClaimResume() {
                mediaLog.error("osascript failed to launch: \(error.localizedDescription)")
                onCompletion(nil)
            }
        }
    }

    /// Returns true when the caller claimed the timeout and must resume the continuation.
    func timeOut() -> Bool {
        guard tryClaimResume() else { return false }
        guard process.isRunning else { return true }
        let processIdentifier = process.processIdentifier
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.process.isRunning else { return }
            mediaLog.error("osascript ignored SIGTERM; sending SIGKILL to \(processIdentifier)")
            kill(processIdentifier, SIGKILL)
        }
        return true
    }

    private func tryClaimResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isResumed { return false }
        isResumed = true
        return true
    }
}
