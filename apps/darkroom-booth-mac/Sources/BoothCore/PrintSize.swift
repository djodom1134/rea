import Foundation

/// Print sizes offered by the Windows app's print-size menu (MENU 210),
/// in inches, portrait orientation (width <= height).
public struct PrintSize: Hashable, Codable, Sendable, CustomStringConvertible {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = min(width, height)
        self.height = max(width, height)
    }

    public var description: String { "\(Self.format(width))x\(Self.format(height))" }

    public init?(_ text: String) {
        let parts = text.lowercased().replacingOccurrences(of: "round", with: "").split(separator: "x")
        guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w > 0, h > 0 else { return nil }
        self.init(width: w, height: h)
    }

    public static let strip2x6 = PrintSize(width: 2, height: 6)
    public static let photo4x6 = PrintSize(width: 4, height: 6)

    public static let legacyMenu: [PrintSize] = [
        "2x6", "4x6", "5x7", "6x8", "2x7", "2x8", "3.5x5", "4x4", "4x5", "4x8",
        "4x10", "4x12", "4x16", "4x18", "5x5", "5x8", "5x10",
    ].compactMap { PrintSize($0) }

    /// Pixel size at the given resolution (dye-sub printers are 300 dpi).
    public func pixels(dpi: Double = 300) -> (width: Int, height: Int) {
        (Int((width * dpi).rounded()), Int((height * dpi).rounded()))
    }

    /// Strips such as 2x6 are printed two-up on a 4x6 sheet and cut by the
    /// printer, so the Windows app rounds half sheets up to an even number of
    /// copies. Returns the sheet size and how many sheets to print.
    public func sheetPlan(copies: Int) -> (sheet: PrintSize, sheets: Int, perSheet: Int) {
        guard copies > 0 else { return (self, 0, 1) }
        if width * 2 <= Self.photo4x6.width + 0.001 && height == Self.photo4x6.height {
            return (Self.photo4x6, (copies + 1) / 2, 2)
        }
        return (self, copies, 1)
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
