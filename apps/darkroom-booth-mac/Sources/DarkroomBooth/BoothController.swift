import AppKit
import BoothCameras
import BoothCore
import BoothHardware
import BoothImaging
import BoothPrinting
import CoreGraphics
import Foundation
import ImageIO

/// Hosts the pure `SessionMachine`: owns timers, the camera, rendering,
/// printing and the session log, and feeds results back as events.
@MainActor
final class BoothController: ObservableObject {
    @Published var configuration = OperatorConfiguration.load() {
        didSet { configuration.save() }
    }
    @Published private(set) var stage: BoothStage = .attract
    @Published private(set) var liveFrame: CGImage?
    @Published private(set) var lastPhoto: CGImage?
    @Published private(set) var lastOutput: CGImage?
    @Published private(set) var colorEffect: ColorEffect = .color
    @Published private(set) var credits = 0
    @Published private(set) var retakesRemaining = 0
    @Published private(set) var message: String?
    @Published private(set) var cameras: [CameraDescriptor] = []
    @Published private(set) var printers: [PrinterDescriptor] = []
    @Published private(set) var printerStatus: PrinterStatus?
    @Published private(set) var isBoothRunning = false

    let printerService = CUPSPrinterService()
    private let renderer = LayoutRenderer()
    private var machine = SessionMachine(settings: BoothSettings())
    private var camera: (any CameraDevice)?
    private var liveViewTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var sessionDirectory: URL?
    private var sessionPhotos: [Int: URL] = [:]
    private var sessionStartedAt: Date?
    private var idleSince = Date()
    private var lastPrint: (url: URL, plan: (sheet: PrintSize, sheets: Int, perSheet: Int))?
    private var log: SessionLog?
    private var sleepActivity: NSObjectProtocol?

    var layout: PrintLayout {
        PrintLayout.builtIn.first { $0.id == configuration.layoutID } ?? .strip(photos: 4)
    }

    // MARK: - Devices

    func refreshDevices() async {
        let hotFolders = configuration.hotFolderPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let providers: [any CameraProvider] = [AVFoundationCameraProvider(), HotFolderCameraProvider(folders: hotFolders)]
        var found: [CameraDescriptor] = []
        for provider in providers { found += await provider.availableCameras() }
        cameras = found
        do {
            printers = try await printerService.printers()
            if configuration.printerName == nil { configuration.printerName = printers.first { $0.isDefault }?.id }
        } catch {
            printers = []
            message = "Could not list printers: \(error.localizedDescription)"
        }
        await refreshPrinterStatus()
    }

    func refreshPrinterStatus() async {
        guard let name = configuration.printerName else {
            printerStatus = nil
            return
        }
        printerStatus = try? await printerService.status(of: name)
    }

    private func makeCamera() throws -> any CameraDevice {
        guard let id = configuration.cameraID, let descriptor = cameras.first(where: { $0.id == id }) else {
            throw CameraError.notConnected
        }
        switch descriptor.backend {
        case .avFoundation:
            return try AVFoundationCameraProvider().makeDevice(for: descriptor)
        case .hotFolder:
            return try HotFolderCameraProvider(folders: []).makeDevice(for: descriptor)
        case .gphoto2, .canonEDSDK, .nikonSDK:
            throw CameraError.backendUnavailable("\(descriptor.backend.rawValue) is not implemented yet")
        }
    }

    // MARK: - Booth mode

    func startBooth() async {
        guard !isBoothRunning else { return }
        var settings = configuration.settings
        settings.photosPerSession = layout.photoCount
        machine = SessionMachine(settings: settings)
        colorEffect = machine.colorEffect
        message = nil
        do {
            let directory = configuration.eventDirectory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            log = try SessionLog(url: directory.appendingPathComponent("Sessions.db"))
            let device = try makeCamera()
            try await device.connect()
            camera = device
            startLiveView(device)
        } catch {
            message = "Booth could not start: \(error)"
            return
        }
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled, .userInitiated],
            reason: "Booth mode"
        )
        isBoothRunning = true
        idleSince = Date()
        stage = machine.stage
    }

    func stopBooth() async {
        timerTask?.cancel()
        liveViewTask?.cancel()
        if let camera { await camera.disconnect() }
        camera = nil
        liveFrame = nil
        if let sleepActivity { ProcessInfo.processInfo.endActivity(sleepActivity) }
        sleepActivity = nil
        isBoothRunning = false
        if machine.stage.isInSession { send(.command(.cancelSession)) }
    }

    private func startLiveView(_ device: any CameraDevice) {
        liveViewTask?.cancel()
        guard device.descriptor.supportsLiveView, configuration.settings.liveViewEnabled else { return }
        let stream = device.liveView()
        liveViewTask = Task { [weak self] in
            for await frame in stream {
                self?.liveFrame = frame
            }
        }
    }

    // MARK: - Events and effects

    func send(_ event: SessionEvent) {
        let effects = machine.handle(event)
        stage = machine.stage
        colorEffect = machine.colorEffect
        credits = machine.credits
        retakesRemaining = max(0, machine.settings.maxRetakes - machine.retakesUsed)
        for effect in effects { perform(effect) }
    }

    private func perform(_ effect: SessionEffect) {
        switch effect {
        case .scheduleTimer(let token, let seconds):
            timerTask?.cancel()
            timerTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
                guard !Task.isCancelled else { return }
                self?.send(.timerFired(token))
            }

        case .sessionStarted:
            let stamp = Self.sessionStamp(Date())
            let directory = configuration.eventDirectory.appendingPathComponent("Sessions/\(stamp)", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            sessionDirectory = directory
            sessionPhotos = [:]
            sessionStartedAt = Date()
            lastPhoto = nil
            lastOutput = nil

        case .playCountdownSound:
            NSSound(named: NSSound.Name("Tink"))?.play()

        case .capture(let photo):
            NSSound(named: NSSound.Name("Grab"))?.play()
            guard let camera, let directory = sessionDirectory else {
                send(.captureFailed(photo: photo, reason: "camera not connected"))
                return
            }
            Task { [weak self] in
                do {
                    let captured = try await camera.capture(into: directory)
                    guard let self else { return }
                    self.sessionPhotos[photo] = captured.fileURL
                    self.lastPhoto = Self.thumbnail(captured.fileURL)
                    self.send(.captureSucceeded(photo: photo))
                } catch {
                    self?.send(.captureFailed(photo: photo, reason: "\(error)"))
                }
            }

        case .pauseLiveView:
            if let camera { Task { await camera.setLiveViewPaused(true) } }

        case .resumeLiveView:
            if let camera { Task { await camera.setLiveViewPaused(false) } }

        case .compose(let photoCount):
            compose(photoCount: photoCount)

        case .discardPhotos:
            sessionPhotos = [:]
            lastPhoto = nil

        case .print(let copies):
            printLast(copies: copies)

        case .colorEffectChanged, .creditsChanged:
            break

        case .insufficientCredits(let have, let need):
            message = "Insert credits to start (\(have) of \(need))"

        case .reprintLast:
            printLast(copies: 1)

        case .sessionFinished(let summary):
            if let start = sessionStartedAt {
                try? log?.record(summary, startedAt: start, duration: Date().timeIntervalSince(start),
                                 idle: start.timeIntervalSince(idleSince), outputPath: lastPrint?.url.path)
            }
            sessionStartedAt = nil
            idleSince = Date()
        }
    }

    private func compose(photoCount: Int) {
        let layout = self.layout
        let photos = (1...max(1, photoCount)).compactMap { sessionPhotos[$0] }
        let effect = colorEffect
        let variables = TemplateVariables.standard(eventName: configuration.eventName, eventDate: Date(), now: Date())
        let renderer = self.renderer
        guard let directory = sessionDirectory else {
            send(.compositionFailed(reason: "no session folder"))
            return
        }
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<(CGImage, URL, (sheet: PrintSize, sheets: Int, perSheet: Int)), Error> in
                Result {
                    let output = try renderer.render(layout, photos: photos, effect: effect, variables: variables, assetsDirectory: nil)
                    try LayoutRenderer.writeJPEG(output, to: directory.appendingPathComponent("output.jpg"), dpi: layout.dpi)
                    let plan = layout.size.sheetPlan(copies: 1)
                    let sheet = try renderer.sheet(repeating: output, perSheet: plan.perSheet)
                    let printURL = directory.appendingPathComponent("print.jpg")
                    try LayoutRenderer.writeJPEG(sheet, to: printURL, dpi: layout.dpi)
                    return (output, printURL, plan)
                }
            }.value
            guard let self else { return }
            switch result {
            case .success(let (image, printURL, plan)):
                self.lastOutput = image
                self.lastPrint = (printURL, plan)
                self.send(.compositionFinished)
            case .failure(let error):
                self.message = "Could not compose the print: \(error)"
                self.send(.compositionFailed(reason: "\(error)"))
            }
        }
    }

    private func printLast(copies: Int) {
        guard let lastPrint, let printer = configuration.printerName else {
            message = "No printer selected"
            return
        }
        let size = layout.size
        let plan = size.sheetPlan(copies: copies)
        let usesGutenprint = printers.first { $0.id == printer }?.makeAndModel?.localizedCaseInsensitiveContains("gutenprint") ?? false
        let media = usesGutenprint
            ? PrintJobRequest.gutenprintMedia(sheetWidthInches: plan.sheet.width, sheetHeightInches: plan.sheet.height, stripsPerSheet: plan.perSheet)
            : nil
        let job = PrintJobRequest(fileURL: lastPrint.url, copies: plan.sheets, media: media,
                                  extraOptions: usesGutenprint ? [:] : ["fit-to-page": "true"])
        Task { [weak self] in
            do {
                _ = try await self?.printerService.submit(job, to: printer)
                await self?.refreshPrinterStatus()
            } catch {
                self?.message = "Print failed: \(error)"
            }
        }
    }

    // MARK: - Helpers

    private static func sessionStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static func thumbnail(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [String: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways as String: true,
            kCGImageSourceCreateThumbnailWithTransform as String: true,
            kCGImageSourceThumbnailMaxPixelSize as String: 1600,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
