import Foundation

public struct PrinterDescriptor: Hashable, Identifiable, Sendable {
    /// CUPS queue name.
    public var id: String
    public var name: String
    public var makeAndModel: String?
    public var deviceURI: String?
    public var isDefault: Bool

    public init(id: String, name: String, makeAndModel: String?, deviceURI: String?, isDefault: Bool) {
        self.id = id
        self.name = name
        self.makeAndModel = makeAndModel
        self.deviceURI = deviceURI
        self.isDefault = isDefault
    }
}

public enum PrinterState: Equatable, Sendable {
    case idle
    case printing
    case stopped(reason: String)
    case unknown(String)
}

public struct PrinterStatus: Equatable, Sendable {
    public var state: PrinterState
    /// `printer-state-reasons`, e.g. `media-empty`, `marker-supply-low`.
    public var reasons: [String]
    /// Remaining media in percent per marker, when the driver reports it (IPP marker-levels).
    public var markerLevels: [String: Int]

    public init(state: PrinterState, reasons: [String] = [], markerLevels: [String: Int] = [:]) {
        self.state = state
        self.reasons = reasons
        self.markerLevels = markerLevels
    }

    public var isReady: Bool {
        if case .stopped = state { return false }
        return !reasons.contains { $0.hasPrefix("media-empty") || $0.hasPrefix("marker-supply-empty") || $0.hasPrefix("offline") }
    }
}

public struct PrintJobRequest: Sendable {
    public var fileURL: URL
    public var copies: Int
    /// CUPS `media` / PageSize keyword, e.g. `w288h432` (4x6) or `w288h432-div2` (two 2x6 strips, cut).
    public var media: String?
    public var extraOptions: [String: String]

    public init(fileURL: URL, copies: Int, media: String? = nil, extraOptions: [String: String] = [:]) {
        self.fileURL = fileURL
        self.copies = copies
        self.media = media
        self.extraOptions = extraOptions
    }
}

public enum PrintError: Error, Equatable, Sendable {
    case printerNotFound(String)
    case notReady(PrinterStatus)
    case submitFailed(String)
}

public protocol PhotoPrinterService: Sendable {
    func printers() async throws -> [PrinterDescriptor]
    func status(of printer: String) async throws -> PrinterStatus
    /// Submits a job and returns the CUPS job id.
    func submit(_ job: PrintJobRequest, to printer: String) async throws -> String
}
