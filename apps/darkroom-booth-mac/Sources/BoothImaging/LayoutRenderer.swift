import BoothCore
import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum RenderError: Error, Equatable {
    case missingPhoto(Int)
    case unreadableImage(String)
    case contextCreationFailed
    case encodeFailed
}

/// Renders a `PrintLayout` with session photos into a print-ready image.
public final class LayoutRenderer: @unchecked Sendable {
    private let ciContext: CIContext

    public init(ciContext: CIContext = CIContext(options: [.useSoftwareRenderer: false])) {
        self.ciContext = ciContext
    }

    /// - Parameters:
    ///   - photos: captured files in session order (photo 1 first).
    ///   - assetsDirectory: base for the layout's relative image paths.
    public func render(_ layout: PrintLayout, photos: [URL], effect: ColorEffect,
                       variables: TemplateVariables, assetsDirectory: URL?) throws -> CGImage {
        let (width, height) = layout.pixelSize
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw RenderError.contextCreationFailed }
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)

        context.setFillColor(cgColor(layout.background))
        context.fill(canvas)
        if let background = layout.backgroundImage {
            context.draw(try loadImage(background, relativeTo: assetsDirectory), in: canvas)
        }

        for cell in layout.cells {
            guard cell.photo >= 1, cell.photo <= photos.count else { throw RenderError.missingPhoto(cell.photo) }
            let rect = deviceRect(cell.frame, canvas: canvas)
            guard var image = CIImage(contentsOf: photos[cell.photo - 1], options: [.applyOrientationProperty: true]) else {
                throw RenderError.unreadableImage(photos[cell.photo - 1].path)
            }
            if let key = cell.chromaKey {
                let backdrop = try key.backgroundImage.map { CIImage(cgImage: try loadImage($0, relativeTo: assetsDirectory)) }
                image = ChromaKeyFilter.apply(key, to: image, background: backdrop)
            }
            image = ColorEffects.apply(effect, to: image)
            let filled = ChromaKeyFilter.aspectFill(image, to: CGRect(origin: .zero, size: rect.size))
            guard let rendered = ciContext.createCGImage(filled, from: CGRect(origin: .zero, size: rect.size)) else {
                throw RenderError.contextCreationFailed
            }
            context.draw(rendered, in: rect)
        }

        if let overlay = layout.overlayImage {
            context.draw(try loadImage(overlay, relativeTo: assetsDirectory), in: canvas)
        }

        for item in layout.texts {
            draw(item, text: variables.replacing(in: item.text), in: context, canvas: canvas)
        }

        guard let image = context.makeImage() else { throw RenderError.contextCreationFailed }
        return image
    }

    /// Places `copies` of a strip side by side on a sheet (2x6 strips on 4x6).
    public func sheet(repeating strip: CGImage, perSheet: Int) throws -> CGImage {
        guard perSheet > 1 else { return strip }
        let width = strip.width * perSheet
        guard let context = CGContext(data: nil, width: width, height: strip.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw RenderError.contextCreationFailed }
        for index in 0..<perSheet {
            context.draw(strip, in: CGRect(x: index * strip.width, y: 0, width: strip.width, height: strip.height))
        }
        guard let image = context.makeImage() else { throw RenderError.contextCreationFailed }
        return image
    }

    public static func writeJPEG(_ image: CGImage, to url: URL, dpi: Double, quality: Double = 0.95) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw RenderError.encodeFailed
        }
        let properties: [String: Any] = [
            kCGImageDestinationLossyCompressionQuality as String: quality,
            kCGImagePropertyDPIWidth as String: dpi,
            kCGImagePropertyDPIHeight as String: dpi,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw RenderError.encodeFailed }
    }

    // MARK: - Helpers

    /// Converts a top-left unit rect into Core Graphics' bottom-left device space.
    func deviceRect(_ frame: UnitRect, canvas: CGRect) -> CGRect {
        CGRect(x: frame.x * canvas.width,
               y: canvas.height - (frame.y + frame.height) * canvas.height,
               width: frame.width * canvas.width,
               height: frame.height * canvas.height).integral
    }

    private func loadImage(_ path: String, relativeTo base: URL?) throws -> CGImage {
        let url = path.hasPrefix("/") || base == nil ? URL(fileURLWithPath: path) : base!.appendingPathComponent(path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw RenderError.unreadableImage(url.path) }
        return image
    }

    private func cgColor(_ color: RGBAColor) -> CGColor {
        CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }

    private func draw(_ item: TextItem, text: String, in context: CGContext, canvas: CGRect) {
        guard !text.isEmpty else { return }
        let rect = deviceRect(item.frame, canvas: canvas)
        let font = CTFontCreateWithName(item.fontName as CFString, item.relativeSize * canvas.height, nil)
        var alignment: CTTextAlignment
        switch item.alignment {
        case .leading: alignment = .left
        case .center: alignment = .center
        case .trailing: alignment = .right
        }
        let paragraph = withUnsafeBytes(of: &alignment) { pointer -> CTParagraphStyle in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size,
                                                  value: pointer.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgColor(item.color),
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attributed.length), path, nil)
        context.saveGState()
        CTFrameDraw(frame, context)
        context.restoreGState()
    }
}
