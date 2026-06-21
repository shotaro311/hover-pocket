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
        mediaService.setElapsedTime(target)
    }

    func skipPlayback(by seconds: TimeInterval) {
        setPlaybackProgress(nowPlaying.progress + seconds)
    }

    func restartPlayback() {
        setPlaybackProgress(0)
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

    func adjustPlaybackRate(by delta: Double) {
        guard nowPlaying.hasMedia else { return }
        let target = (nowPlaying.playbackRate + delta).clamped(to: 0.5...3.0)
        nowPlaying.playbackRate = target
        mediaService.setPlaybackSpeed(target)
    }
}

private final class DisplayBrightnessService {
    static let minimumBrightness = 0.05

    private let bridge = DisplayServicesBridge()
    private let ddcBridge = DDCBrightnessBridge()
    private let softwareBridge = DisplaySoftwareBrightnessBridge()

    @MainActor
    func displays() -> [ControlsDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let displayID = screen.displayID else { return nil }
            let isInternal = CGDisplayIsBuiltin(displayID) != 0
            let hardwareBrightness = bridge.getBrightness(for: displayID)
            let usesHardwareBrightness = hardwareBrightness != nil && bridge.canSetBrightness
            let ddcBrightness = usesHardwareBrightness || isInternal ? nil : ddcBridge.getBrightness(for: displayID)
            let usesDDCBrightness = ddcBrightness != nil
            let usesSoftwareBrightness = !usesHardwareBrightness && !usesDDCBrightness && !isInternal
            let brightness = usesHardwareBrightness
                ? Double(hardwareBrightness ?? 1)
                : (ddcBrightness ?? softwareBridge.brightness(for: displayID))

            return ControlsDisplay(
                id: String(displayID),
                displayID: displayID,
                name: screen.localizedName,
                kind: isInternal ? .internalDisplay : .externalDisplay,
                brightness: brightness.clamped(to: Self.minimumBrightness...1),
                isControllable: usesHardwareBrightness || usesDDCBrightness || usesSoftwareBrightness
            )
        }
    }

    func setBrightness(_ brightness: Double, for displayID: CGDirectDisplayID) -> Bool {
        let normalized = brightness.clamped(to: Self.minimumBrightness...1)
        if bridge.setBrightness(Float(normalized), for: displayID) {
            return true
        }
        guard CGDisplayIsBuiltin(displayID) == 0 else { return false }
        if ddcBridge.setBrightness(normalized, for: displayID) {
            return true
        }
        return softwareBridge.setBrightness(normalized, for: displayID)
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

private final class DDCBrightnessBridge {
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
        var maxBrightness: Int?

        init(avService: CFTypeRef, identity: DisplayIdentity) {
            self.avService = avService
            self.identity = identity
        }
    }

    typealias CreateWithService = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias CopyEDID = @convention(c) (CFTypeRef, UnsafeMutablePointer<Unmanaged<CFData>?>) -> kern_return_t
    typealias ReadI2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> kern_return_t
    typealias WriteI2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> kern_return_t

    private let queue = DispatchQueue(label: "local.codex.hover-pocket.ddc-brightness")
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
                  let value = readBrightness(display)
            else {
                return nil
            }
            display.maxBrightness = value.max
            guard value.max > 0 else { return nil }
            return Double(value.current).clamped(to: 0...Double(value.max)) / Double(value.max)
        }
    }

    func setBrightness(_ brightness: Double, for displayID: CGDirectDisplayID) -> Bool {
        queue.sync {
            guard let display = ddcDisplay(for: displayID) else { return false }
            let maxBrightness: Int
            if let cachedMax = display.maxBrightness, cachedMax > 0 {
                maxBrightness = cachedMax
            } else if let value = readBrightness(display), value.max > 0 {
                maxBrightness = value.max
                display.maxBrightness = value.max
            } else {
                return false
            }
            let rawValue = Int((brightness.clamped(to: DisplayBrightnessService.minimumBrightness...1) * Double(maxBrightness)).rounded())
                .clamped(to: 1...maxBrightness)
            return writeBrightness(rawValue, to: display)
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

    private func readBrightness(_ display: DDCDisplay) -> (current: Int, max: Int)? {
        guard let readI2C, let writeI2C else { return nil }
        var request: [UInt8] = [0x82, 0x01, 0x10]
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
              response[4] == 0x10,
              Self.checksum([0x50] + Array(response.prefix(10))) == response[10]
        else {
            return nil
        }
        let maxBrightness = Int(response[6]) << 8 | Int(response[7])
        let currentBrightness = Int(response[8]) << 8 | Int(response[9])
        guard maxBrightness > 0 else { return nil }
        return (currentBrightness, maxBrightness)
    }

    private func writeBrightness(_ value: Int, to display: DDCDisplay) -> Bool {
        guard let writeI2C else { return false }
        let highByte = UInt8((value >> 8) & 0xFF)
        let lowByte = UInt8(value & 0xFF)
        var request: [UInt8] = [0x84, 0x03, 0x10, highByte, lowByte]
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
    typealias SetPlaybackSpeed = @convention(c) (Float) -> Void

    private let getNowPlayingInfo: GetNowPlayingInfo?
    private let sendCommand: SendCommand?
    private let setElapsedTimeFunction: SetElapsedTime?
    private let setPlaybackSpeedFunction: SetPlaybackSpeed?

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

    func nowPlaying() async -> ControlsNowPlayingState {
        guard let getNowPlayingInfo else { return .empty }
        return await withCheckedContinuation { continuation in
            getNowPlayingInfo(DispatchQueue.global(qos: .utility)) { info in
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

    func setPlaybackSpeed(_ speed: Double) {
        setPlaybackSpeedFunction?(Float(speed.clamped(to: 0.5...3.0)))
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
            progress: elapsed.clamped(to: 0...max(duration, elapsed, 0)),
            duration: max(duration, elapsed, 0),
            isPlaying: playbackRate > 0,
            playbackRate: (playbackRate > 0 ? playbackRate : defaultPlaybackRate).clamped(to: 0.5...3.0)
        )
    }
}
