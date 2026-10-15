import BoothHardware
import Foundation

/// Printing through the local CUPS server. Dye-sub printers the Windows app
/// drove over its own USB libraries (Mitsubishi, DNP/Citizen, Shinko/Sinfonia,
/// Ciaat, Sony) are reached through Gutenprint's dye-sub backends or the
/// vendor's macOS driver (docs/reverse-engineering/printers.md).
public struct CUPSPrinterService: PhotoPrinterService {
    public var connection: CUPSConnection
    public var session: URLSession

    public init(connection: CUPSConnection = .fromEnvironment(), session: URLSession = .shared) {
        self.connection = connection
        self.session = session
    }

    public func printers() async throws -> [PrinterDescriptor] {
        var request = IPP.Request(operation: .cupsGetPrinters, printerURI: nil)
        request.append(.keyword, "requested-attributes",
                       ["printer-name", "printer-info", "printer-make-and-model", "device-uri", "printer-type"])
        let response = try await send(request, path: "/")
        let defaultName = try? await defaultPrinterName()
        return response.groups(tagged: .printerAttributes).compactMap { group in
            guard let name = group["printer-name"].first?.stringValue else { return nil }
            return PrinterDescriptor(
                id: name,
                name: group["printer-info"].first?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? name,
                makeAndModel: group["printer-make-and-model"].first?.stringValue,
                deviceURI: group["device-uri"].first?.stringValue,
                isDefault: name == defaultName
            )
        }
    }

    public func status(of printer: String) async throws -> PrinterStatus {
        var request = IPP.Request(operation: .getPrinterAttributes, printerURI: printerURI(printer))
        request.append(.keyword, "requested-attributes",
                       ["printer-state", "printer-state-reasons", "printer-state-message", "marker-names", "marker-levels"])
        let response = try await send(request, path: "/printers/\(printer)")
        guard response.isSuccess, let group = response.groups(tagged: .printerAttributes).first else {
            throw PrintError.printerNotFound(printer)
        }
        return Self.status(from: group)
    }

    public func submit(_ job: PrintJobRequest, to printer: String) async throws -> String {
        let status = try await status(of: printer)
        guard status.isReady else { throw PrintError.notReady(status) }
        var arguments = ["-d", printer, "-n", String(max(1, job.copies))]
        if let media = job.media { arguments += ["-o", "media=\(media)"] }
        for (key, value) in job.extraOptions.sorted(by: { $0.key < $1.key }) {
            arguments += ["-o", "\(key)=\(value)"]
        }
        arguments.append(job.fileURL.path)
        let output = try await Self.run("/usr/bin/lp", arguments)
        // "request id is QUEUE-123 (1 file(s))"
        if let range = output.range(of: "request id is ") {
            return String(output[range.upperBound...].prefix { !$0.isWhitespace })
        }
        throw PrintError.submitFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func status(from group: IPP.Group) -> PrinterStatus {
        let reasons = group["printer-state-reasons"].compactMap(\.stringValue).filter { $0 != "none" }
        let state: PrinterState
        switch group["printer-state"].first?.intValue {
        case 3: state = .idle
        case 4: state = .printing
        case 5: state = .stopped(reason: group["printer-state-message"].first?.stringValue ?? reasons.first ?? "stopped")
        case let other: state = .unknown(other.map { String($0) } ?? "missing")
        }
        let names = group["marker-names"].compactMap(\.stringValue)
        let levels = group["marker-levels"].compactMap(\.intValue)
        var markerLevels: [String: Int] = [:]
        for (name, level) in zip(names, levels) where level >= 0 {
            markerLevels[name] = level
        }
        return PrinterStatus(state: state, reasons: reasons, markerLevels: markerLevels)
    }

    private func printerURI(_ printer: String) -> String {
        let escaped = printer.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? printer
        return "ipp://localhost/printers/\(escaped)"
    }

    private func send(_ request: IPP.Request, path: String) async throws -> IPP.Response {
        let status: Int
        let data: Data
        switch connection {
        case .domainSocket(let socketPath):
            let response = try await DomainSocketHTTP.post(socketPath: socketPath, path: path, contentType: "application/ipp",
                                                           body: request.encoded())
            status = response.status
            data = response.body
        case .http(let serverURL):
            var urlRequest = URLRequest(url: serverURL.appendingPathComponent(path))
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/ipp", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = request.encoded()
            let (body, response) = try await session.data(for: urlRequest)
            status = (response as? HTTPURLResponse)?.statusCode ?? -1
            data = body
        }
        guard status == 200 else { throw PrintError.submitFailed("CUPS answered HTTP \(status)") }
        return try IPP.decode(data)
    }

    private func defaultPrinterName() async throws -> String? {
        // "system default destination: NAME"
        let output = try await Self.run("/usr/bin/lpstat", ["-d"])
        guard let range = output.range(of: "destination: ") else { return nil }
        return String(output[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func run(_ executable: String, _ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { finished in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(decoding: data, as: UTF8.self)
                if finished.terminationStatus == 0 {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(throwing: PrintError.submitFailed(text.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: PrintError.submitFailed(error.localizedDescription))
            }
        }
    }
}

extension PrintJobRequest {
    /// CUPS media keyword for a print, using Gutenprint's dye-sub page names:
    /// `w288h432` is 4x6 and `-div2` asks the printer to cut it into two 2x6 strips.
    public static func gutenprintMedia(sheetWidthInches: Double, sheetHeightInches: Double, stripsPerSheet: Int) -> String {
        let w = Int((sheetWidthInches * 72).rounded())
        let h = Int((sheetHeightInches * 72).rounded())
        return stripsPerSheet > 1 ? "w\(w)h\(h)-div\(stripsPerSheet)" : "w\(w)h\(h)"
    }
}
