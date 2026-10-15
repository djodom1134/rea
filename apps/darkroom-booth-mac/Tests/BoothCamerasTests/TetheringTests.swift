@testable import BoothCameras
import BoothHardware
import CoreGraphics
import Foundation
import Testing

@Suite struct TetheringTests {
    @Test func libraryCandidatesPutTheOverrideFirstAndAcceptFrameworks() {
        let candidates = LibraryLocator.candidates(
            override: "DARKROOM_EDSDK_PATH",
            environment: ["DARKROOM_EDSDK_PATH": "/opt/sdk/EDSDK.framework"],
            binaryInBundle: "/App/Contents/Frameworks/EDSDK.framework/EDSDK",
            defaults: ["/Library/Frameworks/EDSDK.framework/EDSDK", "/Library/Frameworks/EDSDK.framework/EDSDK"]
        )
        #expect(candidates == [
            "/opt/sdk/EDSDK.framework/EDSDK",
            "/App/Contents/Frameworks/EDSDK.framework/EDSDK",
            "/Library/Frameworks/EDSDK.framework/EDSDK",
        ])
        let plain = LibraryLocator.candidates(override: "X", environment: ["X": ""], defaults: ["/a.dylib"])
        #expect(plain == ["/a.dylib"])
    }

    @Test func missingLibraryReportsEveryAttempt() {
        let result = DynamicLibrary.open("libnothing", candidates: ["/nonexistent/libnothing.dylib"])
        guard case .failure(.backendUnavailable(let message)) = result else {
            Issue.record("expected backendUnavailable, got \(result)")
            return
        }
        #expect(message.contains("libnothing not found"))
        #expect(message.contains("/nonexistent/libnothing.dylib"))
    }

    @Test func edsCapacityIsPackedAsTwoLittleEndianRegisters() {
        let (low, high) = EDSDK.capacityRegisters(freeClusters: 0x7FFF_FFFF, bytesPerSector: 0x1000, reset: true)
        #expect(low == 0x0000_1000_7FFF_FFFF)
        #expect(high == 1)
        // Same bytes as the C struct laid out in memory.
        var fields: (Int32, Int32, Int32, Int32) = (0x7FFF_FFFF, 0x1000, 1, 0)
        let memory = withUnsafeBytes(of: &fields) { ($0.load(as: UInt64.self), $0.load(fromByteOffset: 8, as: UInt64.self)) }
        #expect(memory.0 == low)
        #expect(memory.1 == high)
    }

    @Test func edsErrorsMapToCameraErrors() {
        #expect(EDSDK.error(for: 0) == nil)
        #expect(EDSDK.error(for: 0x80) == .notConnected)
        #expect(EDSDK.error(for: 0x81) == .busy)
        #expect(EDSDK.error(for: 0x8D01) == .failed("Canon EDSDK: autofocus failed (0x8D01)"))
        #expect(EDSDK.error(for: 0x2003) == .failed("Canon EDSDK error 0x00002003"))
    }

    @Test func edsFixedStringsStopAtTheTerminatorOrCapacity() {
        var bytes = [UInt8](repeating: 0, count: 8)
        bytes.replaceSubrange(0 ..< 3, with: Array("EOS".utf8))
        #expect(bytes.withUnsafeBytes { EDSDK.cString($0.baseAddress!, capacity: 8) } == "EOS")
        let full = Array("ABCDEFGH".utf8)
        #expect(full.withUnsafeBytes { EDSDK.cString($0.baseAddress!, capacity: 8) } == "ABCDEFGH")
    }

    @Test func gphoto2ErrorsExplainTheUSBClaim() {
        #expect(GPhoto2.error(for: -105, message: nil) == .notConnected)
        #expect(GPhoto2.error(for: -110, message: nil) == .busy)
        guard case .failed(let message) = GPhoto2.error(for: -53, message: "Could not claim the USB device") else {
            Issue.record("expected failed")
            return
        }
        #expect(message.contains("ptpcamerad"))
    }

    @Test func liveViewBroadcasterDropsFramesWhilePaused() async throws {
        let broadcaster = LiveViewBroadcaster()
        let stream = broadcaster.stream()
        #expect(broadcaster.hasSubscribers)
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let frame = try #require(context.makeImage())
        broadcaster.isPaused = true
        broadcaster.yield(frame)
        broadcaster.isPaused = false
        broadcaster.yield(frame)
        broadcaster.finishAll()
        var received = 0
        for await _ in stream { received += 1 }
        #expect(received == 1)
        #expect(!broadcaster.hasSubscribers)
    }
}
