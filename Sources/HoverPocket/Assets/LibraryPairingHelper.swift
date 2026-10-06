import Foundation
import Darwin

struct LibraryPairingPeer: Codable, Equatable {
    let version: Int
    let role: String
    let nonce: String
    let deviceId: String
    let deviceName: String
    let platform: String
    let groupId: String?
    let folderId: String?
}

struct LibraryPairingEvent: Decodable {
    let event: String
    var code: String?
    var expiresInSeconds: Int?
    var approvalId: String?
    var verification: String?
    var peer: LibraryPairingPeer?
    var groupId: String?
    var folderId: String?
    var reason: String?
}

@MainActor
protocol LibraryPairingHelper: AnyObject {
    var events: AsyncThrowingStream<Data, Error> { get }
    func send(_ value: [String: String]) throws
    func stop()
}

// One child per attempt. Its protocol is never routed to application logs.
@MainActor
final class LibraryPairingHelperProcess: LibraryPairingHelper {
    let events: AsyncThrowingStream<Data, Error>
    private let process = Process()
    private let input = Pipe()
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    init(executable: URL, start: [String: String]) throws {
        let pair = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(16))
        events = pair.stream
        continuation = pair.continuation
        let output = Pipe()
        process.executableURL = executable
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "HOVERPOCKET_PAIRING_TEST_RELAY")
        process.environment = environment
        try process.run()
        // Close the parent's writer so EOF reliably terminates the stream when the child exits.
        try? output.fileHandleForWriting.close()
        let reader = LibraryPairingLineReader(handle: output.fileHandleForReading, continuation: continuation)
        DispatchQueue.global(qos: .utility).async { reader.read() }
        do { try send(start) } catch { stop(); throw error }
    }

    func send(_ value: [String: String]) throws {
        guard process.isRunning else { throw LibraryError.message("接続処理が終了しました。") }
        var data = try JSONSerialization.data(withJSONObject: value)
        guard data.count <= 16_384 else { throw LibraryError.message("接続情報が大きすぎます。") }
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    func stop() {
        continuation.finish()
        try? input.fileHandleForWriting.close()
        guard process.isRunning else { return }
        process.terminate()
        let child = process
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
    }
}

final class LibraryPairingLineReader: @unchecked Sendable {
    let handle: FileHandle
    let continuation: AsyncThrowingStream<Data, Error>.Continuation
    init(handle: FileHandle, continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        self.handle = handle; self.continuation = continuation
    }
    func read() {
        defer { try? handle.close() }
        do {
            var pending = Data()
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                pending.append(data)
                while let newline = pending.firstIndex(of: 10) {
                    guard newline <= 16_384 else { throw LibraryError.message("接続応答の形式が不正です。") }
                    let line = Data(pending.prefix(upTo: newline))
                    pending.removeSubrange(...newline)
                    switch continuation.yield(line) {
                    case .enqueued: break
                    case .dropped: throw LibraryError.message("接続応答が多すぎます。")
                    case .terminated: return
                    @unknown default: return
                    }
                }
                guard pending.count <= 16_384 else { throw LibraryError.message("接続応答の形式が不正です。") }
            }
            guard pending.isEmpty else { throw LibraryError.message("接続応答が途中で終了しました。") }
            continuation.finish()
        } catch { continuation.finish(throwing: error) }
    }
}
