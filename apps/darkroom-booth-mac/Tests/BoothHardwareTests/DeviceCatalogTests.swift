@testable import BoothHardware
import Foundation
import Testing

@Suite struct DeviceCatalogTests {
    @Test func testCameraTableLoadsRecoveredEntries() throws {
        let cameras = try DeviceCatalog.cameras()
        #expect(cameras.count == 252)
        let canon = cameras.filter { $0.vendorID == 0x04a9 }
        let nikon = cameras.filter { $0.vendorID == 0x04b0 }
        #expect(canon.count > 150)
        #expect(nikon.count > 50)
        #expect(DeviceCatalog.camera(vendorID: 0x04b0, productID: 0x0442, in: cameras)?.model == "Z 7")
        #expect(DeviceCatalog.camera(vendorID: 0x04a9, productID: 0x3041, in: cameras)?.preferredBackends.first == .canonEDSDK)
        // Vendor-wide fallback rows.
        #expect(DeviceCatalog.camera(vendorID: 0x07b4, productID: 0x1234, in: cameras)?.model == "SLR")
    }

    @Test func testPrinterTableCoversDyeSubFamilies() throws {
        let printers = try DeviceCatalog.printers()
        #expect(Set(printers.map(\.family)) == ["mitsubishi", "dnp", "sinfonia", "sony"])
        #expect(DeviceCatalog.printer(vendorID: 0x1452, productID: 0x8b01, in: printers)?.model == "DNP DS620")
        #expect(DeviceCatalog.printer(vendorID: 0x06d3, productID: 0x3b50, in: printers)?.route == .vendorDriver)
    }
}
