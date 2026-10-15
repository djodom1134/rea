import BoothHardware
import CoreGraphics
import Foundation

/// Canon, Nikon, Sony, Fujifilm and other PTP cameras through libgphoto2,
/// loaded at runtime (`brew install libgphoto2`). Replaces the Windows app's
/// per-vendor SDK paths for models those SDKs no longer cover.
///
/// macOS's `ptpcamerad` claims PTP cameras when they connect; libgphoto2 then
/// reports a USB claim error and the camera must be released (quit Image
/// Capture/Photos, or `killall ptpcamerad`).
public struct GPhoto2CameraProvider: CameraProvider {
    public let backend = CameraBackendKind.gphoto2

    public init() {}

    /// Why the backend cannot be used, or nil when libgphoto2 loaded.
    public static var unavailableReason: String? {
        if case .failure(let error) = GPhoto2.shared { return "\(error)" }
        return nil
    }

    public func availableCameras() async -> [CameraDescriptor] {
        guard case .success(let gp) = GPhoto2.shared else { return [] }
        let detected = (try? await GPhoto2.queue.run { try gp.autodetect() }) ?? []
        return detected.map {
            CameraDescriptor(id: "gphoto2:\($0.model)", name: "\($0.model) (libgphoto2)", backend: .gphoto2,
                             supportsLiveView: true)
        }
    }

    public func makeDevice(for descriptor: CameraDescriptor) throws -> any CameraDevice {
        guard descriptor.backend == .gphoto2, descriptor.id.hasPrefix("gphoto2:") else {
            throw CameraError.backendUnavailable("not a libgphoto2 camera")
        }
        let gp = try GPhoto2.shared.get()
        return GPhoto2Camera(descriptor: descriptor, model: String(descriptor.id.dropFirst("gphoto2:".count)), library: gp)
    }
}

public final class GPhoto2Camera: CameraDevice, @unchecked Sendable {
    public let descriptor: CameraDescriptor
    public var liveViewInterval: Duration = .milliseconds(40)

    private let model: String
    private let gp: GPhoto2
    private let frames = LiveViewBroadcaster()
    // Touched only on `GPhoto2.queue`.
    private var context: OpaquePointer?
    private var camera: OpaquePointer?
    // Guarded by `lock`.
    private let lock = NSLock()
    private var liveViewTask: Task<Void, Never>?

    init(descriptor: CameraDescriptor, model: String, library: GPhoto2) {
        self.descriptor = descriptor
        self.model = model
        gp = library
    }

    public func connect() async throws {
        try await GPhoto2.queue.run { [self] in
            guard camera == nil else { return }
            // Ports change on replug, so find the model's current port now.
            let port = try gp.autodetect().first { $0.model == model }?.port
            guard let port else { throw CameraError.notConnected }
            let context = gp.contextNew()
            var camera: OpaquePointer?
            do {
                try gp.check(gp.cameraNew(&camera))
                try gp.setPort(camera, path: port)
                try gp.check(gp.cameraInit(camera, context))
            } catch {
                if let camera { _ = gp.cameraUnref(camera) }
                gp.contextUnref(context)
                throw error
            }
            self.context = context
            self.camera = camera
        }
        let task = Task.detached { [weak self] in await self?.runLiveView() }
        lock.withLock { liveViewTask = task }
    }

    public func disconnect() async {
        let task = lock.withLock { () -> Task<Void, Never>? in
            defer { liveViewTask = nil }
            return liveViewTask
        }
        task?.cancel()
        await task?.value
        frames.finishAll()
        _ = try? await GPhoto2.queue.run { [self] in
            if let camera {
                _ = gp.cameraExit(camera, context)
                _ = gp.cameraUnref(camera)
            }
            if let context { gp.contextUnref(context) }
            camera = nil
            context = nil
        }
    }

    public func liveView() -> AsyncStream<CGImage> {
        frames.stream()
    }

    public func setLiveViewPaused(_ paused: Bool) async {
        frames.isPaused = paused
    }

    public func capture(into directory: URL) async throws -> CapturedPhoto {
        try await GPhoto2.queue.run { [self] in
            guard let camera else { throw CameraError.notConnected }
            let (folder, name) = try gp.captureImage(camera, context)
            let data = try gp.download(camera, folder: folder, name: name, context)
            let ext = (name as NSString).pathExtension.lowercased()
            let url = directory.appendingPathComponent(CaptureNaming.nextFileName(extension: ext.isEmpty ? "jpg" : ext))
            try data.write(to: url, options: .atomic)
            return CapturedPhoto(fileURL: url)
        }
    }

    /// Polls preview frames between other camera calls on the shared queue,
    /// so a capture waits for at most one preview.
    private func runLiveView() async {
        var failures = 0
        while !Task.isCancelled {
            if frames.isPaused || !frames.hasSubscribers {
                try? await Task.sleep(for: .milliseconds(100))
                continue
            }
            do {
                let data = try await GPhoto2.queue.run { [self] () -> Data in
                    guard let camera else { throw CameraError.notConnected }
                    return try gp.preview(camera, context)
                }
                failures = 0
                if let frame = ImageDecoding.image(from: data) { frames.yield(frame) }
            } catch CameraError.notConnected {
                break
            } catch {
                // Cameras without live view, or a busy camera mid-capture.
                failures += 1
                if failures >= 25 { break }
                try? await Task.sleep(for: .milliseconds(200))
                continue
            }
            try? await Task.sleep(for: liveViewInterval)
        }
        frames.finishAll()
    }
}

/// Runs blocking device calls one at a time off the cooperative pool.
final class DeviceQueue: @unchecked Sendable {
    private let queue: DispatchQueue

    init(label: String) {
        queue = DispatchQueue(label: label)
    }

    func run<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }
}

/// libgphoto2 2.5 C API, resolved with `dlsym`. Pointers to libgphoto2's
/// opaque types are `OpaquePointer`s.
final class GPhoto2: @unchecked Sendable {
    /// libgphoto2 is not thread-safe, so every call goes through this queue.
    static let queue = DeviceQueue(label: "booth.camera.gphoto2")

    static let shared: Result<GPhoto2, CameraError> = {
        let candidates = LibraryLocator.candidates(
            override: "DARKROOM_LIBGPHOTO2_PATH",
            environment: ProcessInfo.processInfo.environment,
            defaults: [
                "/opt/homebrew/lib/libgphoto2.6.dylib",
                "/usr/local/lib/libgphoto2.6.dylib",
                "/opt/local/lib/libgphoto2.6.dylib",
            ]
        )
        return DynamicLibrary.open("libgphoto2", candidates: candidates).flatMap { library in
            Result { try GPhoto2(library) }.mapError { $0 as? CameraError ?? .backendUnavailable("\($0)") }
        }
    }()

    // gphoto2-camera.h: CameraCaptureType, CameraFileType.
    static let captureImage: Int32 = 0
    static let fileTypeNormal: Int32 = 1
    // gphoto2-port-result.h / gphoto2-result.h.
    static let errorUSBClaim: Int32 = -53
    static let errorModelNotFound: Int32 = -105
    static let errorCameraBusy: Int32 = -110
    /// sizeof(CameraFilePath): char name[128]; char folder[1024].
    static let filePathNameLength = 128
    static let filePathFolderLength = 1024

    typealias Status = Int32
    let contextNew: @convention(c) () -> OpaquePointer?
    let contextUnref: @convention(c) (OpaquePointer?) -> Void
    let cameraNew: @convention(c) (UnsafeMutablePointer<OpaquePointer?>) -> Status
    let cameraInit: @convention(c) (OpaquePointer?, OpaquePointer?) -> Status
    let cameraExit: @convention(c) (OpaquePointer?, OpaquePointer?) -> Status
    let cameraUnref: @convention(c) (OpaquePointer?) -> Status
    let cameraSetPortInfo: @convention(c) (OpaquePointer?, OpaquePointer?) -> Status
    let cameraAutodetect: @convention(c) (OpaquePointer?, OpaquePointer?) -> Status
    let cameraCapture: @convention(c) (OpaquePointer?, Int32, UnsafeMutableRawPointer, OpaquePointer?) -> Status
    let cameraCapturePreview: @convention(c) (OpaquePointer?, OpaquePointer?, OpaquePointer?) -> Status
    let cameraFileGet: @convention(c) (OpaquePointer?, UnsafePointer<CChar>, UnsafePointer<CChar>, Int32, OpaquePointer?,
                                       OpaquePointer?) -> Status
    let fileNew: @convention(c) (UnsafeMutablePointer<OpaquePointer?>) -> Status
    let fileUnref: @convention(c) (OpaquePointer?) -> Status
    let fileGetDataAndSize: @convention(c) (OpaquePointer?, UnsafeMutablePointer<UnsafePointer<CChar>?>,
                                            UnsafeMutablePointer<UInt>) -> Status
    let listNew: @convention(c) (UnsafeMutablePointer<OpaquePointer?>) -> Status
    let listFree: @convention(c) (OpaquePointer?) -> Status
    let listCount: @convention(c) (OpaquePointer?) -> Status
    let listGetName: @convention(c) (OpaquePointer?, Int32, UnsafeMutablePointer<UnsafePointer<CChar>?>) -> Status
    let listGetValue: @convention(c) (OpaquePointer?, Int32, UnsafeMutablePointer<UnsafePointer<CChar>?>) -> Status
    let portInfoListNew: @convention(c) (UnsafeMutablePointer<OpaquePointer?>) -> Status
    let portInfoListLoad: @convention(c) (OpaquePointer?) -> Status
    let portInfoListLookupPath: @convention(c) (OpaquePointer?, UnsafePointer<CChar>) -> Status
    let portInfoListGetInfo: @convention(c) (OpaquePointer?, Int32, UnsafeMutablePointer<OpaquePointer?>) -> Status
    let portInfoListFree: @convention(c) (OpaquePointer?) -> Status
    let resultAsString: @convention(c) (Int32) -> UnsafePointer<CChar>?

    private init(_ library: DynamicLibrary) throws {
        contextNew = try library.symbol("gp_context_new")
        contextUnref = try library.symbol("gp_context_unref")
        cameraNew = try library.symbol("gp_camera_new")
        cameraInit = try library.symbol("gp_camera_init")
        cameraExit = try library.symbol("gp_camera_exit")
        cameraUnref = try library.symbol("gp_camera_unref")
        cameraSetPortInfo = try library.symbol("gp_camera_set_port_info")
        cameraAutodetect = try library.symbol("gp_camera_autodetect")
        cameraCapture = try library.symbol("gp_camera_capture")
        cameraCapturePreview = try library.symbol("gp_camera_capture_preview")
        cameraFileGet = try library.symbol("gp_camera_file_get")
        fileNew = try library.symbol("gp_file_new")
        fileUnref = try library.symbol("gp_file_unref")
        fileGetDataAndSize = try library.symbol("gp_file_get_data_and_size")
        listNew = try library.symbol("gp_list_new")
        listFree = try library.symbol("gp_list_free")
        listCount = try library.symbol("gp_list_count")
        listGetName = try library.symbol("gp_list_get_name")
        listGetValue = try library.symbol("gp_list_get_value")
        portInfoListNew = try library.symbol("gp_port_info_list_new")
        portInfoListLoad = try library.symbol("gp_port_info_list_load")
        portInfoListLookupPath = try library.symbol("gp_port_info_list_lookup_path")
        portInfoListGetInfo = try library.symbol("gp_port_info_list_get_info")
        portInfoListFree = try library.symbol("gp_port_info_list_free")
        // gp_result_as_string lives in libgphoto2; port errors fall back to it too.
        resultAsString = try library.symbol("gp_result_as_string")
    }

    func check(_ status: Status) throws {
        guard status < 0 else { return }
        throw Self.error(for: status, message: resultAsString(status).map { String(cString: $0) })
    }

    static func error(for status: Status, message: String?) -> CameraError {
        switch status {
        case errorModelNotFound: return .notConnected
        case errorCameraBusy: return .busy
        case errorUSBClaim:
            return .failed("libgphoto2 could not claim the camera (\(status)). macOS may be holding it: quit Image Capture "
                + "and Photos, or run `killall ptpcamerad`, then reconnect.")
        default: return .failed("libgphoto2 error \(status): \(message ?? "unknown")")
        }
    }

    struct Detected: Equatable {
        var model: String
        var port: String
    }

    func autodetect() throws -> [Detected] {
        var list: OpaquePointer?
        try check(listNew(&list))
        defer { _ = listFree(list) }
        let context = contextNew()
        defer { contextUnref(context) }
        try check(cameraAutodetect(list, context))
        var result: [Detected] = []
        for index in 0 ..< max(0, listCount(list)) {
            var name: UnsafePointer<CChar>?
            var value: UnsafePointer<CChar>?
            guard listGetName(list, index, &name) >= 0, listGetValue(list, index, &value) >= 0,
                  let name, let value else { continue }
            result.append(Detected(model: String(cString: name), port: String(cString: value)))
        }
        return result
    }

    func setPort(_ camera: OpaquePointer?, path: String) throws {
        var list: OpaquePointer?
        try check(portInfoListNew(&list))
        defer { _ = portInfoListFree(list) }
        try check(portInfoListLoad(list))
        let index = portInfoListLookupPath(list, path)
        try check(index)
        var info: OpaquePointer?
        try check(portInfoListGetInfo(list, index, &info))
        try check(cameraSetPortInfo(camera, info))
    }

    /// Triggers the shutter and returns the new file's folder and name on the camera.
    func captureImage(_ camera: OpaquePointer, _ context: OpaquePointer?) throws -> (folder: String, name: String) {
        let size = Self.filePathNameLength + Self.filePathFolderLength
        let path = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 1)
        defer { path.deallocate() }
        path.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        try check(cameraCapture(camera, Self.captureImage, path, context))
        let name = String(cString: path.assumingMemoryBound(to: CChar.self))
        let folder = String(cString: (path + Self.filePathNameLength).assumingMemoryBound(to: CChar.self))
        return (folder, name)
    }

    func download(_ camera: OpaquePointer, folder: String, name: String, _ context: OpaquePointer?) throws -> Data {
        try withFile { file in
            try check(cameraFileGet(camera, folder, name, Self.fileTypeNormal, file, context))
        }
    }

    func preview(_ camera: OpaquePointer, _ context: OpaquePointer?) throws -> Data {
        try withFile { file in try check(cameraCapturePreview(camera, file, context)) }
    }

    private func withFile(_ fill: (OpaquePointer?) throws -> Void) throws -> Data {
        var file: OpaquePointer?
        try check(fileNew(&file))
        defer { _ = fileUnref(file) }
        try fill(file)
        var bytes: UnsafePointer<CChar>?
        var count: UInt = 0
        try check(fileGetDataAndSize(file, &bytes, &count))
        guard let bytes, count > 0 else { throw CameraError.failed("libgphoto2 returned an empty file") }
        return Data(bytes: bytes, count: Int(count))
    }
}
