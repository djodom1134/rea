import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Animated GIF output for photo sessions (the Windows app's "Animation of
/// photo sessions" with optional boomerang). Replaces gifsicle.
public enum AnimationExporter {
    public static func frames(_ images: [CGImage], boomerang: Bool) -> [CGImage] {
        guard boomerang, images.count > 2 else { return images }
        return images + images.dropFirst().dropLast().reversed()
    }

    public static func writeGIF(_ images: [CGImage], to url: URL, frameDelay: Double, boomerang: Bool = false) throws {
        let sequence = frames(images, boomerang: boomerang)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, sequence.count, nil) else {
            throw RenderError.encodeFailed
        }
        let fileProperties = [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]]
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)
        let frameProperties = [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: frameDelay]]
        for image in sequence {
            CGImageDestinationAddImage(destination, image, frameProperties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw RenderError.encodeFailed }
    }
}
