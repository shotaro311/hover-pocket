@preconcurrency import AVFoundation
import Foundation

enum CameraVerificationCommand {
    static func run() -> Never {
        var outputLines: [String] = []
        let outputURL = outputFileURL()

        func record(_ line: String) {
            outputLines.append(line)
            print(line)
        }

        func finish(_ exitCode: Int32) -> Never {
            if let outputURL {
                let output = outputLines.joined(separator: "\n") + "\n"
                try? output.write(to: outputURL, atomically: true, encoding: .utf8)
            }
            exit(exitCode)
        }

        do {
            try verify(record)
            finish(0)
        } catch {
            record("camera_verify=failed")
            record("error=\(error.localizedDescription)")
            finish(1)
        }
    }

    private static func verify(_ record: (String) -> Void) throws {
        let authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        record("camera_authorization_status=\(authorizationStatus.description)")

        guard authorizationStatus == .authorized else {
            throw CameraVerificationError.permissionNotAuthorized(authorizationStatus.description)
        }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video) else {
            throw CameraVerificationError.noCamera
        }
        record("camera_device=\(device.localizedName)")

        let session = AVCaptureSession()
        session.sessionPreset = .vga640x480
        let input = try AVCaptureDeviceInput(device: device)

        guard session.canAddInput(input) else {
            throw CameraVerificationError.inputUnavailable
        }

        session.beginConfiguration()
        session.addInput(input)
        session.commitConfiguration()
        session.startRunning()
        Thread.sleep(forTimeInterval: 0.8)

        let isRunning = session.isRunning
        record("camera_session_running=\(isRunning)")
        session.stopRunning()

        guard isRunning else {
            throw CameraVerificationError.sessionDidNotStart
        }

        record("camera_verify=ok")
    }

    private static func outputFileURL() -> URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--verify-output") else {
            return nil
        }
        let pathIndex = arguments.index(after: index)
        guard arguments.indices.contains(pathIndex) else {
            return nil
        }
        return URL(fileURLWithPath: arguments[pathIndex])
    }
}

private enum CameraVerificationError: LocalizedError {
    case permissionNotAuthorized(String)
    case noCamera
    case inputUnavailable
    case sessionDidNotStart

    var errorDescription: String? {
        switch self {
        case .permissionNotAuthorized(let status):
            "Camera permission is \(status)."
        case .noCamera:
            "No available camera was detected."
        case .inputUnavailable:
            "The selected camera input cannot be used."
        case .sessionDidNotStart:
            "Camera session did not start."
        }
    }
}

private extension AVAuthorizationStatus {
    var description: String {
        switch self {
        case .authorized:
            "authorized"
        case .denied:
            "denied"
        case .notDetermined:
            "notDetermined"
        case .restricted:
            "restricted"
        @unknown default:
            "unknown"
        }
    }
}
