import Foundation

struct ControlsCapabilitySnapshot: Sendable {
    let displays: [ControlsDisplay]
    let volume: ControlsVolumeState
    let volumeAvailable: Bool
    let media: ControlsNowPlayingState
}

@MainActor
protocol ControlsCapabilityDataSource: AnyObject {
    func snapshot() async throws -> ControlsCapabilitySnapshot
    func setVolume(_ level: Double) async throws -> ControlsVolumeState
    func setMuted(_ muted: Bool) async throws -> ControlsVolumeState
    func setBrightness(_ level: Double, displayID: String) async throws -> ControlsDisplay
    func executeMediaCommand(_ command: String) async throws -> ControlsNowPlayingState
}

@MainActor
final class LiveControlsCapabilityDataSource: ControlsCapabilityDataSource {
    private let store: ControlsStore

    init(store: ControlsStore = .shared) {
        self.store = store
    }

    func snapshot() async throws -> ControlsCapabilitySnapshot {
        let observed = await store.capabilitySnapshot()
        return ControlsCapabilitySnapshot(
            displays: observed.displays,
            volume: observed.volume,
            volumeAvailable: observed.volumeAvailable,
            media: observed.media
        )
    }

    func setVolume(_ level: Double) async throws -> ControlsVolumeState {
        try await store.setVolumeForCapability(level)
    }

    func setMuted(_ muted: Bool) async throws -> ControlsVolumeState {
        try await store.setMutedForCapability(muted)
    }

    func setBrightness(_ level: Double, displayID: String) async throws -> ControlsDisplay {
        try await store.setBrightnessForCapability(level, displayID: displayID)
    }

    func executeMediaCommand(_ command: String) async throws -> ControlsNowPlayingState {
        try await store.executeMediaCommandForCapability(command)
    }
}

@MainActor
final class ControlsCapabilityHandler: PocketCapabilityHandler {
    enum Operation {
        case availability
        case volumeGet
        case volumeSet
        case muteSet
        case brightnessSet
        case mediaCommand

        var key: PocketCapabilityKey {
            switch self {
            case .availability: PocketCapabilityKeys.controlsAvailability
            case .volumeGet: PocketCapabilityKeys.controlsVolumeGet
            case .volumeSet: PocketCapabilityKeys.controlsVolumeSet
            case .muteSet: PocketCapabilityKeys.controlsMuteSet
            case .brightnessSet: PocketCapabilityKeys.controlsBrightnessSet
            case .mediaCommand: PocketCapabilityKeys.controlsMediaCommand
            }
        }

        var isWrite: Bool {
            switch self {
            case .availability, .volumeGet: false
            case .volumeSet, .muteSet, .brightnessSet, .mediaCommand: true
            }
        }
    }

    let operation: Operation
    private let dataSource: any ControlsCapabilityDataSource

    var key: PocketCapabilityKey { operation.key }

    init(operation: Operation, dataSource: any ControlsCapabilityDataSource) {
        self.operation = operation
        self.dataSource = dataSource
    }

    func handle(arguments: CapabilityObject, context: CapabilityHandlerContext) async throws -> CapabilityObject {
        if operation.isWrite {
            _ = try context.requiredIdempotencyKey()
        }
        do {
            switch operation {
            case .availability:
                try requireNoArguments(arguments)
                return try availabilityOutput(await dataSource.snapshot())
            case .volumeGet:
                try requireNoArguments(arguments)
                let snapshot = try await dataSource.snapshot()
                guard snapshot.volumeAvailable else {
                    throw CapabilityHandlerError.unavailable("controls.volume")
                }
                return volumeOutput(snapshot.volume)
            case .volumeSet:
                let level = try arguments.requiredNumber("level", range: 0...1)
                let before = try await dataSource.snapshot()
                guard before.volumeAvailable else {
                    throw CapabilityHandlerError.unavailable("controls.volume")
                }
                let observed = try await dataSource.setVolume(level)
                guard abs(observed.level - level) <= 0.02,
                      observed.isMuted == before.volume.isMuted else {
                    throw CapabilityHandlerError.readbackMismatch("controls.volume")
                }
                return volumeOutput(observed)
            case .muteSet:
                let muted = try arguments.requiredBool("muted")
                let observed = try await dataSource.setMuted(muted)
                guard observed.isMuted == muted else {
                    throw CapabilityHandlerError.readbackMismatch("controls.mute")
                }
                return volumeOutput(observed)
            case .brightnessSet:
                let displayID = try arguments.requiredString("displayId", maxLength: 128)
                let level = try arguments.requiredNumber("level", range: 0.05...1)
                let observed = try await dataSource.setBrightness(level, displayID: displayID)
                guard observed.id == displayID,
                      observed.isControllable,
                      abs(observed.brightness - level) <= 0.03 else {
                    throw CapabilityHandlerError.readbackMismatch("controls.brightness")
                }
                return try brightnessOutput(observed)
            case .mediaCommand:
                let command = try arguments.requiredString("command", maxLength: 16)
                guard ["play_pause", "next", "previous"].contains(command) else {
                    throw CapabilityHandlerError.invalidArgument("command")
                }
                let before = try await dataSource.snapshot().media
                guard before.hasMedia else {
                    throw CapabilityHandlerError.unavailable("controls.media")
                }
                let observed = try await dataSource.executeMediaCommand(command)
                guard observed.hasMedia, mediaChanged(command: command, before: before, observed: observed) else {
                    throw CapabilityHandlerError.readbackMismatch("controls.media")
                }
                return mediaOutput(command: command, state: observed)
            }
        } catch let error as CapabilityHandlerError {
            throw error
        } catch let error as ControlsStore.CapabilityFailure {
            switch error {
            case .unavailable(let field):
                throw CapabilityHandlerError.unavailable(field)
            case .readbackMismatch(let field):
                throw CapabilityHandlerError.readbackMismatch(field)
            }
        } catch {
            throw CapabilityHandlerError.unavailable("controls")
        }
    }

    private func requireNoArguments(_ arguments: CapabilityObject) throws {
        guard arguments.isEmpty else {
            throw CapabilityHandlerError.invalidArgument("arguments")
        }
    }

    private func availabilityOutput(_ snapshot: ControlsCapabilitySnapshot) throws -> CapabilityObject {
        let ids = try snapshot.displays
            .filter(\.isControllable)
            .prefix(16)
            .map { display -> CapabilityValue in
                guard !display.id.isEmpty, display.id.unicodeScalars.count <= 128 else {
                    throw CapabilityHandlerError.readbackMismatch("controls.displayId")
                }
                return .string(display.id)
            }
        return [
            "volumeAvailable": .bool(snapshot.volumeAvailable),
            "brightnessAvailable": .bool(!ids.isEmpty),
            "mediaAvailable": .bool(snapshot.media.hasMedia),
            "displayIds": .array(ids)
        ]
    }

    private func volumeOutput(_ state: ControlsVolumeState) -> CapabilityObject {
        [
            "level": .number(state.level.clamped(to: 0...1)),
            "muted": .bool(state.isMuted)
        ]
    }

    private func brightnessOutput(_ display: ControlsDisplay) throws -> CapabilityObject {
        guard !display.id.isEmpty, display.id.unicodeScalars.count <= 128 else {
            throw CapabilityHandlerError.readbackMismatch("controls.displayId")
        }
        return [
            "displayId": .string(display.id),
            "level": .number(display.brightness.clamped(to: 0...1)),
            "controllable": .bool(display.isControllable)
        ]
    }

    private func mediaOutput(command: String, state: ControlsNowPlayingState) -> CapabilityObject {
        [
            "command": .string(command),
            "available": .bool(state.hasMedia),
            "isPlaying": .bool(state.isPlaying),
            "safeTitle": .string(state.title.prefixingUnicodeScalars(160)),
            "safeSource": .string(state.sourceName.prefixingUnicodeScalars(120))
        ]
    }

    private func mediaChanged(
        command: String,
        before: ControlsNowPlayingState,
        observed: ControlsNowPlayingState
    ) -> Bool {
        if command == "play_pause" {
            return observed.isPlaying != before.isPlaying
        }
        return observed.title != before.title
    }
}
