@testable import BoothCore
@testable import BoothImaging
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Foundation
import Testing

@Suite struct RenderingTests {
    private func solidImage(red: Double, green: Double, blue: Double, size: Int = 64) -> CGImage {
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()!
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Top-left based coordinates.
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return data
    }

    private func writeTemporary(_ image: CGImage) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test func testRendersPhotosIntoCellsAtPrintResolution() throws {
        let red = try writeTemporary(solidImage(red: 1, green: 0, blue: 0))
        let blue = try writeTemporary(solidImage(red: 0, green: 0, blue: 1))
        defer { [red, blue].forEach { try? FileManager.default.removeItem(at: $0) } }
        let layout = PrintLayout(id: "t", name: "t", size: .photo4x6, dpi: 50, cells: [
            PhotoCell(photo: 1, frame: UnitRect(x: 0, y: 0, width: 1, height: 0.5)),
            PhotoCell(photo: 2, frame: UnitRect(x: 0, y: 0.5, width: 1, height: 0.5)),
        ])
        let image = try LayoutRenderer().render(layout, photos: [red, blue], effect: .color,
                                                variables: TemplateVariables(), assetsDirectory: nil)
        #expect(image.width == 200)
        #expect(image.height == 300)
        let top = pixel(image, x: 100, y: 50)
        let bottom = pixel(image, x: 100, y: 250)
        #expect(top[0] > 200)
        #expect(top[2] < 50)
        #expect(bottom[2] > 200)
        #expect(bottom[0] < 50)
    }

    @Test func testMissingPhotoIsReported() {
        let layout = PrintLayout.single4x6()
        #expect(throws: RenderError.missingPhoto(1)) {
            try LayoutRenderer().render(layout, photos: [], effect: .color, variables: TemplateVariables(), assetsDirectory: nil)
        }
    }

    @Test func testStripSheetPlacesTwoCopies() throws {
        let strip = solidImage(red: 0, green: 1, blue: 0, size: 10)
        let sheet = try LayoutRenderer().sheet(repeating: strip, perSheet: 2)
        #expect(sheet.width == 20)
        #expect(sheet.height == 10)
    }

    @Test func testGrayscaleRemovesColour() throws {
        let input = CIImage(cgImage: solidImage(red: 1, green: 0, blue: 0))
        let output = ColorEffects.apply(.grayscale, to: input)
        let rendered = try #require(CIContext().createCGImage(output, from: input.extent))
        let p = pixel(rendered, x: 10, y: 10)
        #expect(abs(Int(p[0]) - Int(p[1])) < 8)
        #expect(abs(Int(p[1]) - Int(p[2])) < 8)
    }

    @Test func testChromaKeyDropsGreenKeepsRed() {
        #expect(abs((ChromaKeyFilter.hue(red: 0, green: 1, blue: 0)) - (120)) <= 0.01)
        let cube = ChromaKeyFilter.cubeData(for: ChromaKey())
        let floats = cube.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let size = 64
        func alpha(r: Int, g: Int, b: Int) -> Float { floats[((b * size + g) * size + r) * 4 + 3] }
        #expect(alpha(r: 0, g: 63, b: 0) == 0)
        #expect(alpha(r: 63, g: 0, b: 0) == 1)
        #expect(alpha(r: 32, g: 32, b: 32) == 1) // grey is never keyed
    }

    @Test func testGIFBoomerangFrameOrder() throws {
        let frames = (0..<4).map { _ in solidImage(red: 0, green: 0, blue: 0, size: 4) }
        #expect(AnimationExporter.frames(frames, boomerang: true).count == 6)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: url) }
        try AnimationExporter.writeGIF(frames, to: url, frameDelay: 0.2, boomerang: true)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 6)
    }
}
