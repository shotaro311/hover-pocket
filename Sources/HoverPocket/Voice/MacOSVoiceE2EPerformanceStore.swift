import Foundation

struct MacOSVoiceE2EPerformanceReceipt: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let mediaAttemptCount: Int
    let currentAttemptAttached: Bool
    let microphoneToAttachedSamplesMilliseconds: [Int]
    let microphoneToAttachedP95Milliseconds: Int?
    let snapshotPublishCount: Int
    let expandedRPCCount: Int
    let realtimeStopRPCCount: Int
    let maximumRealtimeStopRPCCount: Int
    let measurementDurationMilliseconds: Int
    let lastSafeEvent: String

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case mediaAttemptCount
        case currentAttemptAttached
        case microphoneToAttachedSamplesMilliseconds
        case microphoneToAttachedP95Milliseconds
        case snapshotPublishCount
        case expandedRPCCount
        case realtimeStopRPCCount
        case maximumRealtimeStopRPCCount
        case measurementDurationMilliseconds
        case lastSafeEvent
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(mediaAttemptCount, forKey: .mediaAttemptCount)
        try container.encode(currentAttemptAttached, forKey: .currentAttemptAttached)
        try container.encode(
            microphoneToAttachedSamplesMilliseconds,
            forKey: .microphoneToAttachedSamplesMilliseconds
        )
        if let microphoneToAttachedP95Milliseconds {
            try container.encode(
                microphoneToAttachedP95Milliseconds,
                forKey: .microphoneToAttachedP95Milliseconds
            )
        } else {
            try container.encodeNil(forKey: .microphoneToAttachedP95Milliseconds)
        }
        try container.encode(snapshotPublishCount, forKey: .snapshotPublishCount)
        try container.encode(expandedRPCCount, forKey: .expandedRPCCount)
        try container.encode(realtimeStopRPCCount, forKey: .realtimeStopRPCCount)
        try container.encode(
            maximumRealtimeStopRPCCount,
            forKey: .maximumRealtimeStopRPCCount
        )
        try container.encode(
            measurementDurationMilliseconds,
            forKey: .measurementDurationMilliseconds
        )
        try container.encode(lastSafeEvent, forKey: .lastSafeEvent)
    }
}

@MainActor
final class MacOSVoiceE2EPerformanceStore {
    typealias NanosecondClock = () -> UInt64

    static let maximumLatencySamples = 10
    static let allowedKeys: Set<String> = [
        "schemaVersion",
        "mediaAttemptCount",
        "currentAttemptAttached",
        "microphoneToAttachedSamplesMilliseconds",
        "microphoneToAttachedP95Milliseconds",
        "snapshotPublishCount",
        "expandedRPCCount",
        "realtimeStopRPCCount",
        "maximumRealtimeStopRPCCount",
        "measurementDurationMilliseconds",
        "lastSafeEvent"
    ]

    static let shared: MacOSVoiceE2EPerformanceStore? = {
        guard HoverPocketRuntimeEnvironment.shared.isIsolatedVoiceE2E else { return nil }
        return try? MacOSVoiceE2EPerformanceStore(
            receiptURL: HoverPocketRuntimeEnvironment.shared.voiceE2EPerformanceReceiptURL
        )
    }()

    private let receiptURL: URL
    private let nowNanoseconds: NanosecondClock
    private let writeQueue = DispatchQueue(
        label: "local.codex.hover-pocket.voice-e2e-performance-writer",
        qos: .utility
    )
    private var mediaAttemptCount = 0
    private var currentAttemptAttached = false
    private var microphoneRequestStartedAt: UInt64?
    private var measurementStartedAt: UInt64?
    private var microphoneToAttachedSamplesMilliseconds: [Int] = []
    private var snapshotPublishCount = 0
    private var expandedRPCCount = 0
    private var realtimeStopRPCCount = 0
    private var maximumRealtimeStopRPCCount = 0
    private var lastSafeEvent = "initialized"

    init(
        receiptURL: URL,
        nowNanoseconds: @escaping NanosecondClock = { DispatchTime.now().uptimeNanoseconds }
    ) throws {
        self.receiptURL = receiptURL
        self.nowNanoseconds = nowNanoseconds
        try writeSynchronously()
    }

    func beginMediaAttempt() {
        let now = nowNanoseconds()
        mediaAttemptCount = min(mediaAttemptCount + 1, 10_000)
        currentAttemptAttached = false
        microphoneRequestStartedAt = now
        measurementStartedAt = now
        snapshotPublishCount = 0
        expandedRPCCount = 0
        realtimeStopRPCCount = 0
        lastSafeEvent = "media_attempt_started"
        scheduleWrite()
    }

    func recordTransportAttached() {
        guard let microphoneRequestStartedAt else { return }
        let latency = Self.milliseconds(
            from: microphoneRequestStartedAt,
            to: nowNanoseconds()
        )
        microphoneToAttachedSamplesMilliseconds.append(latency)
        if microphoneToAttachedSamplesMilliseconds.count > Self.maximumLatencySamples {
            microphoneToAttachedSamplesMilliseconds.removeFirst(
                microphoneToAttachedSamplesMilliseconds.count - Self.maximumLatencySamples
            )
        }
        self.microphoneRequestStartedAt = nil
        currentAttemptAttached = true
        lastSafeEvent = "transport_attached"
        scheduleWrite()
    }

    func recordSnapshotPublish() {
        guard measurementStartedAt != nil else { return }
        snapshotPublishCount = min(snapshotPublishCount + 1, 100_000)
    }

    func recordExpandedRPC(count: Int = 1) {
        guard measurementStartedAt != nil, count > 0 else { return }
        expandedRPCCount = min(expandedRPCCount + count, 100_000)
        lastSafeEvent = "expanded_rpc"
    }

    func recordRealtimeStopRPC() {
        guard measurementStartedAt != nil else { return }
        realtimeStopRPCCount = min(realtimeStopRPCCount + 1, 100)
        maximumRealtimeStopRPCCount = max(
            maximumRealtimeStopRPCCount,
            realtimeStopRPCCount
        )
        lastSafeEvent = "realtime_stop_rpc"
    }

    func flush(event: String) {
        lastSafeEvent = Self.safeEvent(event)
        scheduleWrite()
    }

    func flushSynchronously(event: String) throws {
        lastSafeEvent = Self.safeEvent(event)
        let data = try JSONEncoder.voiceE2ESorted.encode(snapshot())
        let destination = receiptURL
        try writeQueue.sync {
            try data.write(to: destination, options: .atomic)
        }
    }

    func readback() throws -> MacOSVoiceE2EPerformanceReceipt {
        let data = try writeQueue.sync {
            try Data(contentsOf: receiptURL)
        }
        return try JSONDecoder().decode(MacOSVoiceE2EPerformanceReceipt.self, from: data)
    }

    private func snapshot() -> MacOSVoiceE2EPerformanceReceipt {
        let now = nowNanoseconds()
        let duration = measurementStartedAt.map {
            Self.milliseconds(from: $0, to: now)
        } ?? 0
        return MacOSVoiceE2EPerformanceReceipt(
            schemaVersion: 1,
            mediaAttemptCount: mediaAttemptCount,
            currentAttemptAttached: currentAttemptAttached,
            microphoneToAttachedSamplesMilliseconds: microphoneToAttachedSamplesMilliseconds,
            microphoneToAttachedP95Milliseconds: Self.p95(
                microphoneToAttachedSamplesMilliseconds
            ),
            snapshotPublishCount: snapshotPublishCount,
            expandedRPCCount: expandedRPCCount,
            realtimeStopRPCCount: realtimeStopRPCCount,
            maximumRealtimeStopRPCCount: maximumRealtimeStopRPCCount,
            measurementDurationMilliseconds: duration,
            lastSafeEvent: lastSafeEvent
        )
    }

    private func writeSynchronously() throws {
        let data = try JSONEncoder.voiceE2ESorted.encode(snapshot())
        try FileManager.default.createDirectory(
            at: receiptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: receiptURL, options: .atomic)
    }

    private func scheduleWrite() {
        guard let data = try? JSONEncoder.voiceE2ESorted.encode(snapshot()) else { return }
        let destination = receiptURL
        writeQueue.async {
            try? data.write(to: destination, options: .atomic)
        }
    }

    private static func milliseconds(from start: UInt64, to end: UInt64) -> Int {
        guard end >= start else { return 0 }
        return Int(min((end - start) / 1_000_000, UInt64(Int.max)))
    }

    private static func p95(_ samples: [Int]) -> Int? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let rank = max(1, (sorted.count * 95 + 99) / 100)
        return sorted[rank - 1]
    }

    private static func safeEvent(_ value: String) -> String {
        let allowed = value.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 48...57, 65...90, 95, 97...122:
                true
            default:
                false
            }
        }
        let bounded = String(String.UnicodeScalarView(allowed.prefix(64)))
        return bounded.isEmpty ? "performance_flush" : bounded
    }
}

private extension JSONEncoder {
    static var voiceE2ESorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
