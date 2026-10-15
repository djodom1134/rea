import CoreGraphics
import Foundation

/// A captured still, written to disk by the camera backend.
public struct CapturedPhoto: Sendable {
    public var fileURL: URL
    public var capturedAt: Date

    public init(fileURL: URL, capturedAt: Date = Date()) {
        self.fileURL = fileURL
        self.capturedAt = capturedAt
    }
}

public enum CameraError: Error, Equatable, Sendable {
    case notConnected
    case busy
    case captureTimedOut
    case permissionDenied
    case backendUnavailable(String)
    case failed(String)
}

/// Which integration drives a camera. Mirrors the `CEdgCamera` subclasses in
/// Eventlib.dll, mapped to what exists on macOS (docs/reverse-engineering/cameras.md).
public enum CameraBackendKind: String, Codable, CaseIterable, Sendable {
    /// Webcams, UVC cameras, HDMI capture cards, Continuity Camera (AVFoundation).
    case avFoundation
    /// Canon/Nikon/Sony/Fujifilm tethering through libgphoto2.
    case gphoto2
    /// Canon EDSDK for macOS (bring your own SDK from Canon's developer program).
    case canonEDSDK
    /// Nikon SDK (MAID3) for macOS (bring your own SDK from Nikon).
    case nikonSDK
    /// Any camera that drops files into a folder (Wi-Fi/FTP transfer, Eye-Fi, tether apps).
    /// This was the Windows app's default camera.
    case hotFolder
}

public struct CameraDescriptor: Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var backend: CameraBackendKind
    public var supportsLiveView: Bool

    public init(id: String, name: String, backend: CameraBackendKind, supportsLiveView: Bool) {
        self.id = id
        self.name = name
        self.backend = backend
        self.supportsLiveView = supportsLiveView
    }
}

/// A connected camera. Backends own their device handles and release them in
/// `disconnect()`, which must be safe to call more than once.
public protocol CameraDevice: AnyObject, Sendable {
    var descriptor: CameraDescriptor { get }
    func connect() async throws
    func disconnect() async
    /// Live view frames. Finishes when live view stops or the camera disconnects.
    func liveView() -> AsyncStream<CGImage>
    func setLiveViewPaused(_ paused: Bool) async
    /// Capture one still into `directory` and return the written file.
    func capture(into directory: URL) async throws -> CapturedPhoto
}

public protocol CameraProvider: Sendable {
    var backend: CameraBackendKind { get }
    func availableCameras() async -> [CameraDescriptor]
    func makeDevice(for descriptor: CameraDescriptor) throws -> any CameraDevice
}
