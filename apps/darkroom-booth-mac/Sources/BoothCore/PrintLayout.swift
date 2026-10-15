import Foundation

/// A rectangle in unit coordinates (0...1) of the layout canvas, origin top-left.
public struct UnitRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// An RGBA colour as a `#RRGGBB` or `#RRGGBBAA` string in JSON.
public struct RGBAColor: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let white = RGBAColor(red: 1, green: 1, blue: 1)
    public static let black = RGBAColor(red: 0, green: 0, blue: 0)

    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return nil }
        if text.count == 6 {
            self.init(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255, blue: Double(value & 0xff) / 255)
        } else {
            self.init(red: Double((value >> 24) & 0xff) / 255, green: Double((value >> 16) & 0xff) / 255,
                      blue: Double((value >> 8) & 0xff) / 255, alpha: Double(value & 0xff) / 255)
        }
    }

    public var hex: String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        let base = String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
        return alpha >= 1 ? base : base + String(format: "%02X", byte(alpha))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let color = RGBAColor(hex: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid colour \(text)")
        }
        self = color
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

/// A photo cell: which session photo goes where. In the Windows template
/// model this is an image object bound to `*Photo<n>`.
public struct PhotoCell: Codable, Hashable, Sendable {
    /// 1-based photo number in the session.
    public var photo: Int
    public var frame: UnitRect
    /// Chroma-key dropout for this cell (`DROPOUTCOLOR:` in .xbdr templates).
    public var chromaKey: ChromaKey?

    public init(photo: Int, frame: UnitRect, chromaKey: ChromaKey? = nil) {
        self.photo = photo
        self.frame = frame
        self.chromaKey = chromaKey
    }
}

public struct ChromaKey: Codable, Hashable, Sendable {
    public var keyColor: RGBAColor
    /// Hue tolerance in degrees around the key colour.
    public var tolerance: Double
    /// Image file shown behind the dropped-out pixels.
    public var backgroundImage: String?

    public init(keyColor: RGBAColor = RGBAColor(red: 0, green: 1, blue: 0), tolerance: Double = 30, backgroundImage: String? = nil) {
        self.keyColor = keyColor
        self.tolerance = tolerance
        self.backgroundImage = backgroundImage
    }
}

public struct TextItem: Codable, Hashable, Sendable {
    /// Text with `%Var%` placeholders.
    public var text: String
    public var frame: UnitRect
    public var fontName: String
    /// Font size as a fraction of the canvas height, so text scales with dpi.
    public var relativeSize: Double
    public var color: RGBAColor
    public var alignment: Alignment

    public enum Alignment: String, Codable, Sendable { case leading, center, trailing }

    public init(text: String, frame: UnitRect, fontName: String = "Helvetica Neue", relativeSize: Double = 0.04, color: RGBAColor = .black, alignment: Alignment = .center) {
        self.text = text
        self.frame = frame
        self.fontName = fontName
        self.relativeSize = relativeSize
        self.color = color
        self.alignment = alignment
    }
}

/// The macOS app's print layout document. The Windows `.xbdr` format is not
/// decoded yet (no sample templates were available); this format covers the
/// pieces the booth flow needs and can grow toward it.
public struct PrintLayout: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var size: PrintSize
    public var dpi: Double
    public var background: RGBAColor
    /// Optional full-canvas image drawn under the photos (relative to the layout file).
    public var backgroundImage: String?
    /// Optional full-canvas PNG with transparency drawn over the photos.
    public var overlayImage: String?
    public var cells: [PhotoCell]
    public var texts: [TextItem]

    public init(id: String, name: String, size: PrintSize, dpi: Double = 300, background: RGBAColor = .white,
                backgroundImage: String? = nil, overlayImage: String? = nil, cells: [PhotoCell], texts: [TextItem] = []) {
        self.id = id
        self.name = name
        self.size = size
        self.dpi = dpi
        self.background = background
        self.backgroundImage = backgroundImage
        self.overlayImage = overlayImage
        self.cells = cells
        self.texts = texts
    }

    /// Photos the layout needs; the booth captures this many by default.
    public var photoCount: Int { cells.map(\.photo).max() ?? 0 }

    public var pixelSize: (width: Int, height: Int) { size.pixels(dpi: dpi) }

    /// Classic 2x6 strip: photos stacked vertically with a footer for text.
    public static func strip(photos: Int = 4) -> PrintLayout {
        let margin = 0.06
        let footer = 0.14
        let gap = 0.015
        let usable = 1 - margin - footer
        let cellHeight = (usable - gap * Double(photos - 1)) / Double(photos)
        let cells = (0..<photos).map { i in
            PhotoCell(photo: i + 1, frame: UnitRect(x: margin * 1.5, y: margin * 0.5 + Double(i) * (cellHeight + gap),
                                                     width: 1 - margin * 3, height: cellHeight))
        }
        return PrintLayout(id: "strip-\(photos)", name: "2x6 strip, \(photos) photos", size: .strip2x6, cells: cells, texts: [
            TextItem(text: "%EventName%", frame: UnitRect(x: 0.05, y: 1 - footer + 0.02, width: 0.9, height: footer * 0.5), relativeSize: 0.03),
            TextItem(text: "%Date%", frame: UnitRect(x: 0.05, y: 1 - footer * 0.45, width: 0.9, height: footer * 0.35), relativeSize: 0.018),
        ])
    }

    /// 4x6 with a 2x2 grid of photos.
    public static func grid4x6() -> PrintLayout {
        let m = 0.04
        let footer = 0.12
        let w = (1 - 3 * m) / 2
        let h = (1 - footer - 3 * m) / 2
        var cells: [PhotoCell] = []
        for row in 0..<2 {
            for column in 0..<2 {
                cells.append(PhotoCell(photo: row * 2 + column + 1,
                                       frame: UnitRect(x: m + Double(column) * (w + m), y: m + Double(row) * (h + m), width: w, height: h)))
            }
        }
        return PrintLayout(id: "grid-4x6", name: "4x6, 4 photos", size: .photo4x6, cells: cells, texts: [
            TextItem(text: "%EventName%  %Date%", frame: UnitRect(x: 0.05, y: 1 - footer + 0.01, width: 0.9, height: footer - 0.03), relativeSize: 0.03),
        ])
    }

    /// 4x6 single photo, full bleed.
    public static func single4x6() -> PrintLayout {
        PrintLayout(id: "single-4x6", name: "4x6, 1 photo", size: .photo4x6, cells: [
            PhotoCell(photo: 1, frame: UnitRect(x: 0, y: 0, width: 1, height: 1)),
        ])
    }

    public static let builtIn: [PrintLayout] = [.strip(photos: 4), .strip(photos: 3), .grid4x6(), .single4x6()]
}
