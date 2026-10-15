import Foundation

/// A USB VID/PID entry from the camera table recovered from Eventlib.dll.
public struct CameraModelEntry: Hashable, Sendable {
    public var vendorID: UInt16
    public var productID: UInt16
    /// Eventlib's SDK-type and sub-type codes (meaning partly inferred; see cameras.md).
    public var sdkType: UInt8
    public var sdkSubtype: UInt8
    public var model: String

    public var vendor: String {
        switch vendorID {
        case 0x04a9: return "Canon"
        case 0x04b0: return "Nikon"
        case 0x04cb: return "Fujifilm"
        case 0x07b4: return "Olympus"
        default: return String(format: "%04x", vendorID)
        }
    }

    /// Backends to try on macOS, best first. Vendor SDKs are preferred for
    /// models they still support; libgphoto2 covers the rest.
    public var preferredBackends: [CameraBackendKind] {
        switch vendorID {
        case 0x04a9: return [.canonEDSDK, .gphoto2]
        case 0x04b0: return [.nikonSDK, .gphoto2]
        default: return [.gphoto2]
        }
    }
}

public struct PrinterModelEntry: Hashable, Sendable {
    public enum Route: String, Sendable {
        case gutenprint
        case gutenprintExperimental = "gutenprint-experimental"
        case vendorDriver = "vendor-driver"
    }

    public var vendorID: UInt16
    public var productID: UInt16
    public var model: String
    public var family: String
    public var route: Route
    /// Suggested Gutenprint model name; unverified against a Gutenprint install.
    public var gutenprintModel: String?
}

public enum DeviceCatalogError: Error, Equatable {
    case missingResource(String)
    case malformedLine(resource: String, line: Int)
}

/// USB device tables shipped as resources so they stay reviewable as data.
public enum DeviceCatalog {
    public static func cameras() throws -> [CameraModelEntry] {
        try rows("camera-usb-models", columns: 5).map { line, f in
            guard let vid = UInt16(f[0], radix: 16), let pid = UInt16(f[1], radix: 16),
                  let type = UInt8(f[2].dropFirst(2), radix: 16), let sub = UInt8(f[3].dropFirst(2), radix: 16)
            else { throw DeviceCatalogError.malformedLine(resource: "camera-usb-models", line: line) }
            return CameraModelEntry(vendorID: vid, productID: pid, sdkType: type, sdkSubtype: sub, model: f[4])
        }
    }

    public static func printers() throws -> [PrinterModelEntry] {
        try rows("printer-usb-models", columns: 6).map { line, f in
            guard let vid = UInt16(f[0], radix: 16), let pid = UInt16(f[1], radix: 16),
                  let route = PrinterModelEntry.Route(rawValue: f[4])
            else { throw DeviceCatalogError.malformedLine(resource: "printer-usb-models", line: line) }
            return PrinterModelEntry(vendorID: vid, productID: pid, model: f[2], family: f[3], route: route,
                                     gutenprintModel: f[5].isEmpty ? nil : f[5])
        }
    }

    /// Looks up a camera by USB ids. 0xffff product ids in the table are
    /// vendor-wide fallbacks.
    public static func camera(vendorID: UInt16, productID: UInt16, in entries: [CameraModelEntry]) -> CameraModelEntry? {
        entries.first { $0.vendorID == vendorID && $0.productID == productID }
            ?? entries.first { $0.vendorID == vendorID && $0.productID == 0xffff }
    }

    public static func printer(vendorID: UInt16, productID: UInt16, in entries: [PrinterModelEntry]) -> PrinterModelEntry? {
        entries.first { $0.vendorID == vendorID && $0.productID == productID }
    }

    private static func rows(_ name: String, columns: Int) throws -> [(Int, [String])] {
        guard let url = Bundle.module.url(forResource: name, withExtension: "tsv") else {
            throw DeviceCatalogError.missingResource(name)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        var result: [(Int, [String])] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where index > 0 {
            if line.isEmpty { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == columns else {
                throw DeviceCatalogError.malformedLine(resource: name, line: index + 1)
            }
            result.append((index + 1, fields))
        }
        return result
    }
}
