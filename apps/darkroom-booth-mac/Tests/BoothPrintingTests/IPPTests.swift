@testable import BoothHardware
@testable import BoothPrinting
import XCTest

final class IPPTests: XCTestCase {
    func testRequestEncodingMatchesRFC8010Layout() {
        var request = IPP.Request(operation: .getPrinterAttributes, requestID: 7, printerURI: "ipp://localhost/printers/DS620")
        request.append(.keyword, "requested-attributes", ["printer-state", "marker-levels"])
        let data = request.encoded()
        XCTAssertEqual(Array(data.prefix(8)), [0x01, 0x01, 0x00, 0x0B, 0x00, 0x00, 0x00, 0x07])
        XCTAssertEqual(data[8], 0x01)
        XCTAssertEqual(data.last, 0x03)
        // The second keyword value is an additional value: empty name.
        let marker = Data("marker-levels".utf8)
        let range = data.range(of: marker)!
        XCTAssertEqual(Array(data[(range.lowerBound - 5)..<range.lowerBound]), [0x44, 0x00, 0x00, 0x00, UInt8(marker.count)])
    }

    func testDecodePrinterStatusWithMarkerLevels() throws {
        var body = Data([0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07, 0x01])
        body.append(attribute(0x47, "attributes-charset", Data("utf-8".utf8)))
        body.append(0x04)
        body.append(attribute(0x23, "printer-state", Data([0, 0, 0, 5])))
        body.append(attribute(0x44, "printer-state-reasons", Data("media-empty-error".utf8)))
        body.append(attribute(0x44, "", Data("cups-waiting-for-job-completed".utf8)))
        body.append(attribute(0x41, "marker-names", Data("Ribbon".utf8)))
        body.append(attribute(0x21, "marker-levels", Data([0, 0, 0, 12])))
        body.append(0x03)

        let response = try IPP.decode(body)
        XCTAssertTrue(response.isSuccess)
        XCTAssertEqual(response.requestID, 7)
        let group = try XCTUnwrap(response.groups(tagged: .printerAttributes).first)
        XCTAssertEqual(group["printer-state-reasons"].count, 2)

        let status = CUPSPrinterService.status(from: group)
        XCTAssertEqual(status.state, .stopped(reason: "media-empty-error"))
        XCTAssertEqual(status.markerLevels, ["Ribbon": 12])
        XCTAssertFalse(status.isReady)
    }

    func testDecodeRejectsTruncatedData() {
        XCTAssertThrowsError(try IPP.decode(Data([0x01, 0x01, 0x00])))
        var body = Data([0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x04, 0x21, 0x00, 0x05])
        body.append(Data("abc".utf8))
        XCTAssertThrowsError(try IPP.decode(body))
    }

    func testGutenprintMediaNames() {
        XCTAssertEqual(PrintJobRequest.gutenprintMedia(sheetWidthInches: 4, sheetHeightInches: 6, stripsPerSheet: 2), "w288h432-div2")
        XCTAssertEqual(PrintJobRequest.gutenprintMedia(sheetWidthInches: 5, sheetHeightInches: 7, stripsPerSheet: 1), "w360h504")
    }

    private func attribute(_ tag: UInt8, _ name: String, _ value: Data) -> Data {
        var data = Data([tag])
        data.appendUInt16(UInt16(name.utf8.count))
        data.append(Data(name.utf8))
        data.appendUInt16(UInt16(value.count))
        data.append(value)
        return data
    }
}
