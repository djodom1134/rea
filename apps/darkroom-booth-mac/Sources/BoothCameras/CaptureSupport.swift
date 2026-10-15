import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum CaptureNaming {
    private static let lock = NSLock()
    private static var counter = 0

    /// `IMG_yyyyMMdd_HHmmss_NNNN.ext`, unique within the process.
    static func nextFileName(extension ext: String, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let n = lock.withLock { () -> Int in
            counter += 1
            return counter
        }
        return String(format: "IMG_%@_%04d.%@", formatter.string(from: date), n % 10_000, ext)
    }
}

enum JPEGEncoding {
    static func encode(_ image: CGImage, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CameraErrorBridge.encodeFailed
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality as String: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CameraErrorBridge.encodeFailed }
        return data as Data
    }
}

enum CameraErrorBridge: Error {
    case encodeFailed
}

enum ImageDecoding {
    /// Decodes a live view frame (JPEG from both libgphoto2 and EDSDK).
    static func image(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
