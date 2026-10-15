import BoothHardware
import CoreGraphics
import Foundation

/// Canon EOS cameras through Canon's EDSDK for macOS, the same SDK family the
/// Windows app ships (EDSDK 13.11). Canon licenses the SDK per developer, so it
/// is not bundled: put `EDSDK.framework` in the app's Frameworks folder,
/// `~/Library/Frameworks` or `/Library/Frameworks`, or set
/// `DARKROOM_EDSDK_PATH`. Without it, Canon cameras use libgphoto2.
public struct CanonEDSDKCameraProvider: CameraProvider {
    public let backend = CameraBackendKind.canonEDSDK

    public init() {}

    public static var unavailableReason: String? {
        if case .failure(let error) = EDSDK.shared { return "\(error)" }
        return nil
    }

    public func availableCameras() async -> [CameraDescriptor] {
        guard case .success(let sdk) = EDSDK.shared else { return [] }
        let names = (try? await sdk.thread.run { try sdk.cameraDescriptions() }) ?? []
        return names.map {
            CameraDescriptor(id: "edsdk:\($0)", name: "\($0) (Canon EDSDK)", backend: .canonEDSDK, supportsLiveView: true)
        }
    }

    public func makeDevice(for descriptor: CameraDescriptor) throws -> any CameraDevice {
        guard descriptor.backend == .canonEDSDK, descriptor.id.hasPrefix("edsdk:") else {
            throw CameraError.backendUnavailable("not a Canon EDSDK camera")
        }
        let sdk = try EDSDK.shared.get()
        return CanonEDSDKCamera(descriptor: descriptor, deviceDescription: String(descriptor.id.dropFirst("edsdk:".count)),
                                sdk: sdk)
    }
}

public final class CanonEDSDKCamera: CameraDevice, @unchecked Sendable {
    public let descriptor: CameraDescriptor
    public var captureTimeout: Duration = .seconds(30)
    public var liveViewInterval: Duration = .milliseconds(40)

    private let deviceDescription: String
    private let sdk: EDSDK
    private let frames = LiveViewBroadcaster()
    // Touched only on `sdk.thread`.
    private var camera: OpaquePointer?
    private var retainedSelf: Unmanaged<CanonEDSDKCamera>?
    // Guarded by `lock`.
    private let lock = NSLock()
    private var pending: (directory: URL, continuation: CheckedContinuation<CapturedPhoto, Error>)?
    private var liveViewTask: Task<Void, Never>?

    init(descriptor: CameraDescriptor, deviceDescription: String, sdk: EDSDK) {
        self.descriptor = descriptor
        self.deviceDescription = deviceDescription
        self.sdk = sdk
    }

    public func connect() async throws {
        try await sdk.thread.run { [self] in
            guard camera == nil else { return }
            guard let found = try sdk.findCamera(description: deviceDescription) else { throw CameraError.notConnected }
            do {
                try sdk.check(sdk.openSession(found))
                // The handler's context must stay valid until it is unregistered in `disconnect()`.
                let unmanaged = Unmanaged.passRetained(self)
                retainedSelf = unmanaged
                try sdk.check(sdk.setObjectEventHandler(found, EDSDK.objectEventAll, canonObjectEventHandler,
                                                        unmanaged.toOpaque()))
                var saveTo = EDSDK.saveToHost
                try sdk.check(sdk.setPropertyData(found, EDSDK.propSaveTo, 0, 4, &saveTo))
                // Tell the camera the host has room, or it refuses to shoot with no card.
                let capacity = EDSDK.capacityRegisters(freeClusters: 0x7FFF_FFFF, bytesPerSector: 0x1000, reset: true)
                try sdk.check(sdk.setCapacity(found, capacity.0, capacity.1))
            } catch {
                _ = sdk.setObjectEventHandler(found, EDSDK.objectEventAll, nil, nil)
                retainedSelf?.release()
                retainedSelf = nil
                _ = sdk.closeSession(found)
                _ = sdk.release(found)
                throw error
            }
            camera = found
        }
        let task = Task.detached { [weak self] in await self?.runLiveView() }
        lock.withLock { liveViewTask = task }
    }

    public func disconnect() async {
        let (task, waiting) = lock.withLock { () -> (Task<Void, Never>?, CheckedContinuation<CapturedPhoto, Error>?) in
            defer {
                liveViewTask = nil
                pending = nil
            }
            return (liveViewTask, pending?.continuation)
        }
        task?.cancel()
        await task?.value
        waiting?.resume(throwing: CameraError.notConnected)
        frames.finishAll()
        _ = try? await sdk.thread.run { [self] in
            guard let camera else { return }
            var output = EDSDK.evfOutputDeviceTFT
            _ = sdk.setPropertyData(camera, EDSDK.propEvfOutputDevice, 0, 4, &output)
            _ = sdk.setObjectEventHandler(camera, EDSDK.objectEventAll, nil, nil)
            _ = sdk.closeSession(camera)
            _ = sdk.release(camera)
            self.camera = nil
            retainedSelf?.release()
            retainedSelf = nil
        }
    }

    public func liveView() -> AsyncStream<CGImage> {
        frames.stream()
    }

    public func setLiveViewPaused(_ paused: Bool) async {
        frames.isPaused = paused
    }

    public func capture(into directory: URL) async throws -> CapturedPhoto {
        let timeout = captureTimeout
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.finishCapture(.failure(CameraError.captureTimedOut))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            let busy = lock.withLock { () -> Bool in
                if pending != nil { return true }
                pending = (directory, continuation)
                return false
            }
            if busy {
                continuation.resume(throwing: CameraError.busy)
                return
            }
            Task { [self] in
                do {
                    try await sdk.thread.run { [self] in
                        guard let camera else { throw CameraError.notConnected }
                        // Full press with autofocus, then release. The file arrives as a
                        // DirItemRequestTransfer event (see `handleObjectEvent`).
                        let pressed = sdk.sendCommand(camera, EDSDK.commandPressShutterButton, EDSDK.shutterCompletely)
                        _ = sdk.sendCommand(camera, EDSDK.commandPressShutterButton, EDSDK.shutterOff)
                        try sdk.check(pressed)
                    }
                } catch {
                    finishCapture(.failure(error))
                }
            }
        }
    }

    private func finishCapture(_ result: Result<CapturedPhoto, Error>) {
        let waiting = lock.withLock { () -> CheckedContinuation<CapturedPhoto, Error>? in
            defer { pending = nil }
            return pending?.continuation
        }
        waiting?.resume(with: result)
    }

    /// Called by EDSDK on whichever thread it delivers events on. Owns `item`.
    fileprivate func handleObjectEvent(_ event: UInt32, _ item: OpaquePointer?) {
        guard event == EDSDK.objectEventDirItemRequestTransfer, let item else {
            if let item { _ = sdk.release(item) }
            return
        }
        let directory = lock.withLock { pending?.directory }
        Task { [self] in
            let result: Result<CapturedPhoto, Error>
            do {
                result = .success(try await sdk.thread.run { [self] () -> CapturedPhoto in
                    defer { _ = sdk.release(item) }
                    // RAW+JPEG sends two transfers; keep the first, cancel any extra.
                    guard let directory else {
                        _ = sdk.downloadCancel(item)
                        throw CancellationError()
                    }
                    return try sdk.download(item, into: directory)
                })
            } catch is CancellationError {
                return
            } catch {
                result = .failure(error)
            }
            finishCapture(result)
        }
    }

    private func runLiveView() async {
        var started = false
        var failures = 0
        while !Task.isCancelled {
            if frames.isPaused || !frames.hasSubscribers {
                try? await Task.sleep(for: .milliseconds(100))
                continue
            }
            do {
                let data = try await sdk.thread.run { [self] () -> Data? in
                    guard let camera else { throw CameraError.notConnected }
                    if !started {
                        var output = EDSDK.evfOutputDevicePC
                        try sdk.check(sdk.setPropertyData(camera, EDSDK.propEvfOutputDevice, 0, 4, &output))
                        started = true
                    }
                    return try sdk.downloadEvfFrame(camera)
                }
                failures = 0
                if let data, let frame = ImageDecoding.image(from: data) { frames.yield(frame) }
            } catch CameraError.notConnected {
                break
            } catch {
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

private let canonObjectEventHandler: EDSDK.ObjectEventHandler = { event, item, context in
    guard let context else {
        return 0
    }
    Unmanaged<CanonEDSDKCamera>.fromOpaque(context).takeUnretainedValue().handleObjectEvent(event, item)
    return 0
}

/// A thread with a running run loop. EDSDK delivers object events through the
/// run loop of the thread that initialised it, so all SDK calls go here.
final class RunLoopThread: @unchecked Sendable {
    private let runLoop: CFRunLoop

    init(name: String) {
        let ready = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var loop: CFRunLoop?
        let thread = Thread {
            loop = CFRunLoopGetCurrent()
            // A port keeps the run loop alive with no other sources.
            RunLoop.current.add(NSMachPort(), forMode: .default)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = name
        thread.start()
        ready.wait()
        runLoop = loop!
    }

    func run<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
                continuation.resume(with: Result { try body() })
            }
            CFRunLoopWakeUp(runLoop)
        }
    }

    func sync<T>(_ body: @escaping () throws -> T) throws -> T {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<T, Error>?
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
            result = Result { try body() }
            done.signal()
        }
        CFRunLoopWakeUp(runLoop)
        done.wait()
        return try result!.get()
    }
}

/// Canon EDSDK (13.x, macOS) C API, resolved with `dlsym`. EDSDK refs are
/// `OpaquePointer`s; `EdsError` and `EdsUInt32` are `UInt32`.
final class EDSDK: @unchecked Sendable {
    typealias Status = UInt32
    typealias ObjectEventHandler = @convention(c) (UInt32, OpaquePointer?, UnsafeMutableRawPointer?) -> Status

    static let shared: Result<EDSDK, CameraError> = {
        let bundled = Bundle.main.privateFrameworksURL?.appendingPathComponent("EDSDK.framework/EDSDK").path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = LibraryLocator.candidates(
            override: "DARKROOM_EDSDK_PATH",
            environment: ProcessInfo.processInfo.environment,
            binaryInBundle: bundled,
            defaults: [
                "\(home)/Library/Frameworks/EDSDK.framework/EDSDK",
                "/Library/Frameworks/EDSDK.framework/EDSDK",
            ]
        )
        return DynamicLibrary.open("Canon EDSDK", candidates: candidates).flatMap { library in
            Result { try EDSDK(library) }.mapError { $0 as? CameraError ?? .backendUnavailable("\($0)") }
        }
    }()

    // EDSDKTypes.h
    static let errOK: Status = 0
    static let errDeviceNotFound: Status = 0x80
    static let errDeviceBusy: Status = 0x81
    static let errObjectNotReady: Status = 0xA102
    static let errTakePictureAFFailed: Status = 0x8D01
    static let errTakePictureNoCard: Status = 0x8D07
    static let propSaveTo: UInt32 = 0x0000_000B
    static let propEvfOutputDevice: UInt32 = 0x0000_0500
    static let saveToHost: UInt32 = 2
    static let evfOutputDeviceTFT: UInt32 = 1
    static let evfOutputDevicePC: UInt32 = 2
    static let objectEventAll: UInt32 = 0x0000_0200
    static let objectEventDirItemRequestTransfer: UInt32 = 0x0000_0208
    static let commandPressShutterButton: UInt32 = 0x0000_0004
    static let shutterOff: Int32 = 0
    static let shutterCompletely: Int32 = 3
    static let fileCreateAlways: UInt32 = 1
    static let accessReadWrite: UInt32 = 2
    /// EdsDeviceInfo: char szPortName[256]; char szDeviceDescription[256]; EdsUInt32 deviceSubType; EdsUInt32 reserved.
    static let deviceInfoSize = 520
    static let deviceInfoDescriptionOffset = 256
    /// EdsDirectoryItemInfo: EdsUInt64 size; EdsBool isFolder; EdsUInt32 groupID; EdsUInt32 option;
    /// EdsChar szFileName[256]; EdsUInt32 format; EdsUInt32 dateTime (288 bytes with padding).
    static let directoryItemInfoSize = 288
    static let directoryItemInfoNameOffset = 20

    /// `EdsSetCapacity` takes `EdsCapacity { EdsInt32 numberOfFreeClusters; EdsInt32 bytesPerSector; EdsBool reset; }`
    /// by value. Swift cannot declare a C struct parameter for a `dlsym` pointer, so this packs it the way both
    /// arm64 (AAPCS64) and x86_64 (System V) pass a 12-byte integer struct: two 64-bit registers, little-endian.
    static func capacityRegisters(freeClusters: Int32, bytesPerSector: Int32, reset: Bool) -> (UInt64, UInt64) {
        let low = UInt64(UInt32(bitPattern: freeClusters)) | (UInt64(UInt32(bitPattern: bytesPerSector)) << 32)
        return (low, reset ? 1 : 0)
    }

    let thread = RunLoopThread(name: "booth.camera.edsdk")

    let initializeSDK: @convention(c) () -> Status
    let getCameraList: @convention(c) (UnsafeMutablePointer<OpaquePointer?>) -> Status
    let getChildCount: @convention(c) (OpaquePointer?, UnsafeMutablePointer<UInt32>) -> Status
    let getChildAtIndex: @convention(c) (OpaquePointer?, Int32, UnsafeMutablePointer<OpaquePointer?>) -> Status
    let getDeviceInfo: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer) -> Status
    let release: @convention(c) (OpaquePointer?) -> UInt32
    let openSession: @convention(c) (OpaquePointer?) -> Status
    let closeSession: @convention(c) (OpaquePointer?) -> Status
    let setPropertyData: @convention(c) (OpaquePointer?, UInt32, Int32, UInt32, UnsafeRawPointer) -> Status
    let setCapacity: @convention(c) (OpaquePointer?, UInt64, UInt64) -> Status
    let setObjectEventHandler: @convention(c) (OpaquePointer?, UInt32, ObjectEventHandler?, UnsafeMutableRawPointer?) -> Status
    let sendCommand: @convention(c) (OpaquePointer?, UInt32, Int32) -> Status
    let getDirectoryItemInfo: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer) -> Status
    let createFileStream: @convention(c) (UnsafePointer<CChar>, UInt32, UInt32, UnsafeMutablePointer<OpaquePointer?>) -> Status
    let createMemoryStream: @convention(c) (UInt64, UnsafeMutablePointer<OpaquePointer?>) -> Status
    let download: @convention(c) (OpaquePointer?, UInt64, OpaquePointer?) -> Status
    let downloadComplete: @convention(c) (OpaquePointer?) -> Status
    let downloadCancel: @convention(c) (OpaquePointer?) -> Status
    let createEvfImageRef: @convention(c) (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>) -> Status
    let downloadEvfImage: @convention(c) (OpaquePointer?, OpaquePointer?) -> Status
    let getPointer: @convention(c) (OpaquePointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Status
    let getLength: @convention(c) (OpaquePointer?, UnsafeMutablePointer<UInt64>) -> Status

    private init(_ library: DynamicLibrary) throws {
        initializeSDK = try library.symbol("EdsInitializeSDK")
        getCameraList = try library.symbol("EdsGetCameraList")
        getChildCount = try library.symbol("EdsGetChildCount")
        getChildAtIndex = try library.symbol("EdsGetChildAtIndex")
        getDeviceInfo = try library.symbol("EdsGetDeviceInfo")
        release = try library.symbol("EdsRelease")
        openSession = try library.symbol("EdsOpenSession")
        closeSession = try library.symbol("EdsCloseSession")
        setPropertyData = try library.symbol("EdsSetPropertyData")
        setCapacity = try library.symbol("EdsSetCapacity")
        setObjectEventHandler = try library.symbol("EdsSetObjectEventHandler")
        sendCommand = try library.symbol("EdsSendCommand")
        getDirectoryItemInfo = try library.symbol("EdsGetDirectoryItemInfo")
        createFileStream = try library.symbol("EdsCreateFileStream")
        createMemoryStream = try library.symbol("EdsCreateMemoryStream")
        download = try library.symbol("EdsDownload")
        downloadComplete = try library.symbol("EdsDownloadComplete")
        downloadCancel = try library.symbol("EdsDownloadCancel")
        createEvfImageRef = try library.symbol("EdsCreateEvfImageRef")
        downloadEvfImage = try library.symbol("EdsDownloadEvfImage")
        getPointer = try library.symbol("EdsGetPointer")
        getLength = try library.symbol("EdsGetLength")
        // The SDK stays initialised for the life of the process.
        let initialize = initializeSDK
        try thread.sync { try Self.check(initialize()) }
    }

    func check(_ status: Status) throws {
        try Self.check(status)
    }

    static func check(_ status: Status) throws {
        if let error = error(for: status) { throw error }
    }

    static func error(for status: Status) -> CameraError? {
        switch status {
        case errOK: return nil
        case errDeviceNotFound: return .notConnected
        case errDeviceBusy: return .busy
        case errTakePictureAFFailed: return .failed("Canon EDSDK: autofocus failed (0x8D01)")
        case errTakePictureNoCard: return .failed("Canon EDSDK: no memory card (0x8D07)")
        default: return .failed(String(format: "Canon EDSDK error 0x%08X", status))
        }
    }

    /// The device descriptions of connected cameras. Call on `thread`.
    func cameraDescriptions() throws -> [String] {
        try withCameras { cameras in try cameras.map { try deviceDescription(of: $0) } }
    }

    /// A retained ref to the camera with this description. Call on `thread`.
    func findCamera(description: String) throws -> OpaquePointer? {
        var list: OpaquePointer?
        try check(getCameraList(&list))
        defer { _ = release(list) }
        var count: UInt32 = 0
        try check(getChildCount(list, &count))
        for index in 0 ..< Int32(count) {
            var camera: OpaquePointer?
            try check(getChildAtIndex(list, index, &camera))
            if (try? deviceDescription(of: camera)) == description { return camera }
            _ = release(camera)
        }
        return nil
    }

    private func withCameras<T>(_ body: ([OpaquePointer?]) throws -> T) throws -> T {
        var list: OpaquePointer?
        try check(getCameraList(&list))
        defer { _ = release(list) }
        var count: UInt32 = 0
        try check(getChildCount(list, &count))
        var cameras: [OpaquePointer?] = []
        defer { cameras.forEach { _ = release($0) } }
        for index in 0 ..< Int32(count) {
            var camera: OpaquePointer?
            try check(getChildAtIndex(list, index, &camera))
            cameras.append(camera)
        }
        return try body(cameras)
    }

    private func deviceDescription(of camera: OpaquePointer?) throws -> String {
        let info = UnsafeMutableRawPointer.allocate(byteCount: Self.deviceInfoSize, alignment: 8)
        defer { info.deallocate() }
        info.initializeMemory(as: UInt8.self, repeating: 0, count: Self.deviceInfoSize)
        try check(getDeviceInfo(camera, info))
        return Self.cString(info + Self.deviceInfoDescriptionOffset, capacity: 256)
    }

    /// Downloads a transferred item into `directory`. Call on `thread`; the caller releases `item`.
    func download(_ item: OpaquePointer, into directory: URL) throws -> CapturedPhoto {
        let info = UnsafeMutableRawPointer.allocate(byteCount: Self.directoryItemInfoSize, alignment: 8)
        defer { info.deallocate() }
        info.initializeMemory(as: UInt8.self, repeating: 0, count: Self.directoryItemInfoSize)
        do {
            try check(getDirectoryItemInfo(item, info))
        } catch {
            _ = downloadCancel(item)
            throw error
        }
        let size = info.loadUnaligned(as: UInt64.self)
        let name = Self.cString(info + Self.directoryItemInfoNameOffset, capacity: 256)
        let ext = (name as NSString).pathExtension.lowercased()
        let url = directory.appendingPathComponent(CaptureNaming.nextFileName(extension: ext.isEmpty ? "jpg" : ext))
        var stream: OpaquePointer?
        do {
            try check(createFileStream(url.path, Self.fileCreateAlways, Self.accessReadWrite, &stream))
        } catch {
            _ = downloadCancel(item)
            throw error
        }
        defer { _ = release(stream) }
        try check(download(item, size, stream))
        try check(downloadComplete(item))
        return CapturedPhoto(fileURL: url)
    }

    /// One live view JPEG, or nil when the camera has no frame ready yet. Call on `thread`.
    func downloadEvfFrame(_ camera: OpaquePointer) throws -> Data? {
        var stream: OpaquePointer?
        try check(createMemoryStream(0, &stream))
        defer { _ = release(stream) }
        var image: OpaquePointer?
        try check(createEvfImageRef(stream, &image))
        defer { _ = release(image) }
        let status = downloadEvfImage(camera, image)
        if status == Self.errObjectNotReady { return nil }
        try check(status)
        var pointer: UnsafeMutableRawPointer?
        var length: UInt64 = 0
        try check(getPointer(stream, &pointer))
        try check(getLength(stream, &length))
        guard let pointer, length > 0 else { return nil }
        return Data(bytes: pointer, count: Int(length))
    }

    static func cString(_ pointer: UnsafeRawPointer, capacity: Int) -> String {
        let bytes = UnsafeRawBufferPointer(start: pointer, count: capacity)
        let end = bytes.firstIndex(of: 0) ?? capacity
        return String(decoding: bytes[..<end], as: UTF8.self)
    }
}
