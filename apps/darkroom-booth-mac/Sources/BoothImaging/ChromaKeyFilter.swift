import BoothCore
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Green/blue screen dropout via a colour cube that makes pixels near the key
/// hue transparent. Replaces the Windows app's per-cell `DROPOUTCOLOR` chroma
/// key (CChromaKeyInfo).
public enum ChromaKeyFilter {
    private static let cubeSize = 64

    public static func cubeData(for key: ChromaKey) -> Data {
        let keyHue = hue(red: key.keyColor.red, green: key.keyColor.green, blue: key.keyColor.blue)
        let tolerance = max(1, key.tolerance)
        let size = cubeSize
        var values = [Float](repeating: 0, count: size * size * size * 4)
        var offset = 0
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let red = Double(r) / Double(size - 1)
                    let green = Double(g) / Double(size - 1)
                    let blue = Double(b) / Double(size - 1)
                    let (h, s, v) = hsv(red: red, green: green, blue: blue)
                    var distance = abs(h - keyHue)
                    if distance > 180 { distance = 360 - distance }
                    // Only saturated, reasonably bright pixels near the key hue drop out;
                    // a soft edge over half the tolerance avoids hard fringes.
                    var alpha = 1.0
                    if s > 0.25 && v > 0.15 {
                        if distance < tolerance * 0.5 {
                            alpha = 0
                        } else if distance < tolerance {
                            alpha = (distance - tolerance * 0.5) / (tolerance * 0.5)
                        }
                    }
                    // Premultiplied output.
                    values[offset] = Float(red * alpha)
                    values[offset + 1] = Float(green * alpha)
                    values[offset + 2] = Float(blue * alpha)
                    values[offset + 3] = Float(alpha)
                    offset += 4
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    public static func apply(_ key: ChromaKey, to image: CIImage, background: CIImage?) -> CIImage {
        let filter = CIFilter.colorCube()
        filter.cubeDimension = Float(cubeSize)
        filter.cubeData = cubeData(for: key)
        filter.inputImage = image
        guard let keyed = filter.outputImage else { return image }
        guard let background else { return keyed }
        let scaled = aspectFill(background, to: image.extent)
        return keyed.composited(over: scaled).cropped(to: image.extent)
    }

    static func aspectFill(_ image: CIImage, to rect: CGRect) -> CIImage {
        let scale = max(rect.width / image.extent.width, rect.height / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = rect.midX - scaled.extent.midX
        let dy = rect.midY - scaled.extent.midY
        return scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy)).cropped(to: rect)
    }

    static func hue(red: Double, green: Double, blue: Double) -> Double {
        hsv(red: red, green: green, blue: blue).h
    }

    static func hsv(red: Double, green: Double, blue: Double) -> (h: Double, s: Double, v: Double) {
        let maxValue = max(red, green, blue)
        let minValue = min(red, green, blue)
        let delta = maxValue - minValue
        var h = 0.0
        if delta > 0 {
            if maxValue == red {
                h = 60 * ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxValue == green {
                h = 60 * ((blue - red) / delta + 2)
            } else {
                h = 60 * ((red - green) / delta + 4)
            }
        }
        if h < 0 { h += 360 }
        let s = maxValue == 0 ? 0 : delta / maxValue
        return (h, s, maxValue)
    }
}
