@testable import BoothHardware
@testable import BoothPrinting
import Testing

@Suite struct IPPTests {
    @Test func testRequestEncodingMatchesRFC8010Layout() {
        var request = IPP.Request(operation: .getPrinterAttributes, requestID: 7, printerURI: "ipp://localhost/printers/DS620")
        request.append(.keyword, "requested-attributes", ["printer-state", "marker-levels"])
        let data = request.encoded()
        #expect(Array(data.prefix(8)) == [0x01, 0x01, 0x00, 0x0B, 0x00, 0x00, 0x00, 0x07])
        #expect(data[8] == 0x01)
        #expect(data.last == 0x03)
        // The second keyword value is an additional value: empty name.
        let marker = Data("marker-levels".utf8)
        let range = data.range(of: marker)!
        #expect(Array(data[(range.lowerBound - 5)..<range.lowerBound]) == [0x44, 0x00, 0x00, 0x00, UInt8(marker.count)])
    }

    @Test func testDecodePrinterStatusWithMarkerLevels() throws {
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
        #expect(response.isSuccess)
        #expect(response.requestID == 7)
        let group = try #require(response.groups(tagged: .printerAttributes).first)
        #expect(group["printer-state-reasons"].count == 2)

        let status = CUPSPrinterService.status(from: group)
        #expect(status.state == .stopped(reason: "media-empty-error"))
        #expect(status.markerLevels == ["Ribbon": 12])
        #expect(!(status.isReady))
    }

    @Test func testDecodeRejectsTruncatedData() {
        #expect(throws: IPP.DecodeError.truncated) { try IPP.decode(Data([0x01, 0x01, 0x00])) }
        var body = Data([0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x04, 0x21, 0x00, 0x05])
        body.append(Data("abc".utf8))
        #expect(throws: IPP.DecodeError.truncated) { try IPP.decode(body) }
    }

    @Test func testGutenprintMediaNames() {
        #expect(PrintJobRequest.gutenprintMedia(sheetWidthInches: 4, sheetHeightInches: 6, stripsPerSheet: 2) == "w288h432-div2")
        #expect(PrintJobRequest.gutenprintMedia(sheetWidthInches: 5, sheetHeightInches: 7, stripsPerSheet: 1) == "w360h504")
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
