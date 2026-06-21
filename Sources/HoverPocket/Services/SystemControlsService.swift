import AppKit
import AudioToolbox
import CoreGraphics
import CoreAudio
import Darwin
import Foundation

@MainActor
final class ControlsStore: ObservableObject {
    static let shared = ControlsStore()

    @Published private(set) var displays: [ControlsDisplay] = []
    @Published private(set) var volume: ControlsVolumeState = .empty
    @Published private(set) var nowPlaying: ControlsNowPlayingState = .empty

    private let brightnessService = DisplayBrightnessService()
    private let volumeService = SystemVolumeService()
    private let mediaService = MediaRemoteService()
    private var pollTimer: Timer?
    private var refreshTask: Task<Void, Never>?

    func startPolling() {
        refresh()
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        pollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let displays = brightnessService.displays()
            let nextVolume = await volumeService.currentState()
            let nextNowPlaying = await mediaService.nowPlaying()
            guard !Task.isCancelled else { return }
            self.displays = displays
            self.volume = nextVolume
            self.nowPlaying = nextNowPlaying
        }
    }

    func setBrightness(_ brightness: Double, for displayID: ControlsDisplay.ID) {
        guard let index = displays.firstIndex(where: { $0.id == displayID }) else { return }
        guard displays[index].isControllable else { return }
        let normalized = brightness.clamped(to: 0...1)
        let cgDisplayID = CGDirectDisplayID(displays[index].displayID)
        displays[index].brightness = normalized
        _ = brightnessService.setBrightness(normalized, for: cgDisplayID)
    }

    func toggleDisplayBrightness(for displayID: ControlsDisplay.ID) {
        guard let display = displays.first(where: { $0.id == displayID }) else { return }
        guard display.isControllable else { return }
        let target = display.brightness <= 0.05 ? 1.0 : 0.0
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
        mediaService.setElapsedTime(target)
    }

    func skipPlayback(by seconds: TimeInterval) {
        setPlaybackProgress(nowPlaying.progress + seconds)
    }

    func togglePlayback() {
        guard nowPlaying.hasMedia else { return }
        nowPlaying.isPlaying.toggle()
        mediaService.togglePlayPause()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }
}

private final class DisplayBrightnessService {
    private let bridge = DisplayServicesBridge()

    @MainActor
    func displays() -> [ControlsDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let displayID = screen.displayID else { return nil }
            let brightness = bridge.getBrightness(for: displayID)
            let isInternal = CGDisplayIsBuiltin(displayID) != 0
            return ControlsDisplay(
                id: String(displayID),
                displayID: displayID,
                name: screen.localizedName,
                kind: isInternal ? .internalDisplay : .externalDisplay,
                brightness: Double(brightness ?? 0),
                isControllable: brightness != nil && bridge.canSetBrightness
            )
        }
    }

    func setBrightness(_ brightness: Double, for displayID: CGDirectDisplayID) -> Bool {
        bridge.setBrightness(Float(brightness.clamped(to: 0...1)), for: displayID)
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

private final class SystemVolumeService: @unchecked Sendable {
    func currentState() async -> ControlsVolumeState {
        await Task.detached(priority: .utility) {
            Self.readCurrentState()
        }.value ?? .empty
    }

    func setVolume(_ level: Double) async {
        let normalized = Float32(level.clamped(to: 0...1))
        await Task.detached(priority: .utility) {
            _ = Self.setVolume(normalized)
            if normalized > 0 {
                _ = Self.setMuted(false)
            }
        }.value
    }

    func setMuted(_ isMuted: Bool) async {
        await Task.detached(priority: .utility) {
            _ = Self.setMuted(isMuted)
        }.value
    }

    private static func readCurrentState() -> ControlsVolumeState? {
        guard let deviceID = defaultOutputDevice() else { return nil }
        let volume = readVolume(deviceID: deviceID) ?? 0
        let isMuted = readMuted(deviceID: deviceID) ?? false
        return ControlsVolumeState(level: Double(volume).clamped(to: 0...1), isMuted: isMuted)
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

    private static func readVolume(deviceID: AudioDeviceID) -> Float32? {
        var address = volumeAddress()
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        guard status == noErr else { return nil }
        return volume.clamped(to: 0...1)
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

private final class MediaRemoteService: @unchecked Sendable {
    typealias GetNowPlayingInfo = @convention(c) (DispatchQueue, @escaping @convention(block) (NSDictionary?) -> Void) -> Void
    typealias SendCommand = @convention(c) (Int32, CFDictionary?) -> Void
    typealias SetElapsedTime = @convention(c) (Double) -> Void

    private let getNowPlayingInfo: GetNowPlayingInfo?
    private let sendCommand: SendCommand?
    private let setElapsedTimeFunction: SetElapsedTime?

    init() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY) else {
            getNowPlayingInfo = nil
            sendCommand = nil
            setElapsedTimeFunction = nil
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
    }

    func nowPlaying() async -> ControlsNowPlayingState {
        guard let getNowPlayingInfo else { return .empty }
        return await withCheckedContinuation { continuation in
            getNowPlayingInfo(.main) { info in
                continuation.resume(returning: Self.parseNowPlaying(info))
            }
        }
    }

    func togglePlayPause() {
        sendCommand?(2, nil)
    }

    func setElapsedTime(_ elapsedTime: TimeInterval) {
        setElapsedTimeFunction?(max(0, elapsedTime))
    }

    private static func parseNowPlaying(_ info: NSDictionary?) -> ControlsNowPlayingState {
        guard let info else { return .empty }
        let title = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
        let artist = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
        let album = info["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? ""
        let duration = (info["kMRMediaRemoteNowPlayingInfoDuration"] as? NSNumber)?.doubleValue ?? 0
        let elapsed = (info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? NSNumber)?.doubleValue ?? 0
        let playbackRate = (info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0
        let artworkData = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data
        let hasMedia = !title.isEmpty || duration > 0 || artworkData != nil
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
            progress: elapsed.clamped(to: 0...max(duration, elapsed, 0)),
            duration: max(duration, elapsed, 0),
            isPlaying: playbackRate > 0
        )
    }
}
