@preconcurrency import AVFoundation
import BoothHardware
import CoreImage
import Foundation

/// Webcams, UVC cameras, HDMI capture cards and Continuity Camera. Replaces the
/// Windows app's DirectShow webcam/DV path.
public struct AVFoundationCameraProvider: CameraProvider {
    public let backend = CameraBackendKind.avFoundation

    public init() {}

    public func availableCameras() async -> [CameraDescriptor] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.map {
            CameraDescriptor(id: $0.uniqueID, name: $0.localizedName, backend: .avFoundation, supportsLiveView: true)
        }
    }

    public func makeDevice(for descriptor: CameraDescriptor) throws -> any CameraDevice {
        guard descriptor.backend == .avFoundation else {
            throw CameraError.backendUnavailable("not an AVFoundation camera")
        }
        return AVFoundationCamera(descriptor: descriptor)
    }
}

public final class AVFoundationCamera: NSObject, CameraDevice, @unchecked Sendable {
    public let descriptor: CameraDescriptor

    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "booth.camera.avfoundation.session")
    private let frameQueue = DispatchQueue(label: "booth.camera.avfoundation.frames")
    private let ciContext = CIContext()

    // Guarded by `lock`.
    private let lock = NSLock()
    private var subscribers: [UUID: AsyncStream<CGImage>.Continuation] = [:]
    private var paused = false
    private var latestFrame: CGImage?
    private var pendingPhoto: CheckedContinuation<Data, Error>?
    private var hasPhotoOutput = false
    private var connected = false

    public init(descriptor: CameraDescriptor) {
        self.descriptor = descriptor
    }

    public func connect() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { throw CameraError.permissionDenied }
        default:
            throw CameraError.permissionDenied
        }
        guard let device = AVCaptureDevice(uniqueID: descriptor.id) else { throw CameraError.notConnected }
        let input = try AVCaptureDeviceInput(device: device)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [self] in
                session.beginConfiguration()
                session.sessionPreset = session.canSetSessionPreset(.photo) ? .photo : .high
                guard session.canAddInput(input) else {
                    session.commitConfiguration()
                    continuation.resume(throwing: CameraError.failed("cannot add camera input"))
                    return
                }
                session.addInput(input)
                videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                videoOutput.alwaysDiscardsLateVideoFrames = true
                videoOutput.setSampleBufferDelegate(self, queue: frameQueue)
                if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
                let photoSupported = session.canAddOutput(photoOutput)
                if photoSupported { session.addOutput(photoOutput) }
                session.commitConfiguration()
                session.startRunning()
                lock.withLock {
                    hasPhotoOutput = photoSupported
                    connected = true
                }
                continuation.resume()
            }
        }
    }

    public func disconnect() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [self] in
                if session.isRunning { session.stopRunning() }
                for input in session.inputs { session.removeInput(input) }
                for output in session.outputs { session.removeOutput(output) }
                continuation.resume()
            }
        }
        let (streams, pending) = lock.withLock { () -> ([AsyncStream<CGImage>.Continuation], CheckedContinuation<Data, Error>?) in
            let streams = Array(subscribers.values)
            subscribers.removeAll()
            let pending = pendingPhoto
            pendingPhoto = nil
            connected = false
            return (streams, pending)
        }
        streams.forEach { $0.finish() }
        pending?.resume(throwing: CameraError.notConnected)
    }

    public func liveView() -> AsyncStream<CGImage> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            lock.withLock { subscribers[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { _ = self.subscribers.removeValue(forKey: id) }
            }
        }
    }

    public func setLiveViewPaused(_ paused: Bool) async {
        lock.withLock { self.paused = paused }
    }

    public func capture(into directory: URL) async throws -> CapturedPhoto {
        let (isConnected, usePhotoOutput) = lock.withLock { (connected, hasPhotoOutput) }
        guard isConnected else { throw CameraError.notConnected }
        let data: Data
        if usePhotoOutput {
            data = try await withCheckedThrowingContinuation { continuation in
                let busy = lock.withLock { () -> Bool in
                    if pendingPhoto != nil { return true }
                    pendingPhoto = continuation
                    return false
                }
                if busy {
                    continuation.resume(throwing: CameraError.busy)
                    return
                }
                let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                photoOutput.capturePhoto(with: settings, delegate: self)
            }
        } else {
            // Some capture cards expose video only: use the newest frame.
            guard let frame = lock.withLock({ latestFrame }) else { throw CameraError.captureTimedOut }
            data = try JPEGEncoding.encode(frame, quality: 0.95)
        }
        let url = directory.appendingPathComponent(CaptureNaming.nextFileName(extension: "jpg"))
        try data.write(to: url, options: .atomic)
        return CapturedPhoto(fileURL: url)
    }

    private func finishPhoto(_ result: Result<Data, Error>) {
        let pending = lock.withLock { () -> CheckedContinuation<Data, Error>? in
            defer { pendingPhoto = nil }
            return pendingPhoto
        }
        pending?.resume(with: result)
    }
}

extension AVFoundationCamera: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let frame = ciContext.createCGImage(image, from: image.extent) else { return }
        let targets = lock.withLock { () -> [AsyncStream<CGImage>.Continuation] in
            latestFrame = frame
            return paused ? [] : Array(subscribers.values)
        }
        for target in targets { target.yield(frame) }
    }
}

extension AVFoundationCamera: AVCapturePhotoCaptureDelegate {
    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            finishPhoto(.failure(CameraError.failed(error.localizedDescription)))
        } else if let data = photo.fileDataRepresentation() {
            finishPhoto(.success(data))
        } else {
            finishPhoto(.failure(CameraError.failed("camera returned no image data")))
        }
    }
}
