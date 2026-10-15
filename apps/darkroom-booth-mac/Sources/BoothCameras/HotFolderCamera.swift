import BoothHardware
import CoreGraphics
import Foundation

/// The Windows app's default camera: any device or tether tool that writes
/// image files into a folder. `capture` waits for the next complete file.
public struct HotFolderCameraProvider: CameraProvider {
    public let backend = CameraBackendKind.hotFolder
    public var folders: [URL]

    public init(folders: [URL]) {
        self.folders = folders
    }

    public func availableCameras() async -> [CameraDescriptor] {
        folders.map {
            CameraDescriptor(id: $0.path, name: "Hot folder: \($0.lastPathComponent)", backend: .hotFolder, supportsLiveView: false)
        }
    }

    public func makeDevice(for descriptor: CameraDescriptor) throws -> any CameraDevice {
        guard descriptor.backend == .hotFolder else { throw CameraError.backendUnavailable("not a hot folder") }
        return HotFolderCamera(descriptor: descriptor, folder: URL(fileURLWithPath: descriptor.id, isDirectory: true))
    }
}

public final class HotFolderCamera: CameraDevice, @unchecked Sendable {
    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "tif", "tiff"]

    public let descriptor: CameraDescriptor
    public let folder: URL
    public var timeout: Duration = .seconds(30)
    public var pollInterval: Duration = .milliseconds(250)

    private let lock = NSLock()
    private var seen: Set<String> = []

    public init(descriptor: CameraDescriptor, folder: URL) {
        self.descriptor = descriptor
        self.folder = folder
    }

    public func connect() async throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CameraError.notConnected
        }
        let existing = try currentImages()
        lock.withLock { seen = Set(existing.map(\.path)) }
    }

    public func disconnect() async {}

    public func liveView() -> AsyncStream<CGImage> {
        AsyncStream { $0.finish() }
    }

    public func setLiveViewPaused(_ paused: Bool) async {}

    public func capture(into directory: URL) async throws -> CapturedPhoto {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var candidate: (url: URL, size: Int)?
        while clock.now < deadline {
            try Task.checkCancellation()
            let known = lock.withLock { seen }
            if let next = try currentImages().first(where: { !known.contains($0.path) }) {
                let size = (try? next.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
                // Treat the file as complete once its size is stable across two polls.
                if let previous = candidate, previous.url == next, previous.size == size, size > 0 {
                    _ = lock.withLock { seen.insert(next.path) }
                    let target = directory.appendingPathComponent(next.lastPathComponent)
                    if FileManager.default.fileExists(atPath: target.path) {
                        try FileManager.default.removeItem(at: target)
                    }
                    try FileManager.default.copyItem(at: next, to: target)
                    return CapturedPhoto(fileURL: target)
                }
                candidate = (next, size)
            }
            try await Task.sleep(for: pollInterval)
        }
        throw CameraError.captureTimedOut
    }

    private func currentImages() throws -> [URL] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey], options: [.skipsHiddenFiles]
        )
        return urls
            .filter { Self.imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return a < b
            }
    }
}
