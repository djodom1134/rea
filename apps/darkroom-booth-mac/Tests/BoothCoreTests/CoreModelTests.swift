@testable import BoothCore
import XCTest

final class CoreModelTests: XCTestCase {
    func testTemplateVariablesReplaceKnownAndKeepUnknown() {
        let vars = TemplateVariables(["EventName": "Smith Wedding"])
        XCTAssertEqual(vars.replacing(in: "%EventName% - %Unknown% 100%%"), "Smith Wedding - %Unknown% 100%")
        XCTAssertEqual(vars.replacing(in: "%eventname%"), "Smith Wedding")
        XCTAssertEqual(vars.replacing(in: "50% off"), "50% off")
    }

    func testStandardVariablesIncludeTime24() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13 UTC
        let vars = TemplateVariables.standard(eventName: "E", eventDate: date, now: date, calendar: calendar,
                                              locale: Locale(identifier: "en_US"))
        XCTAssertEqual(vars.values["Time24"], "22:13")
        XCTAssertEqual(vars.values["EventName"], "E")
    }

    func testPrintSizeParsingAndStripPlan() {
        XCTAssertEqual(PrintSize("6x2"), PrintSize(width: 2, height: 6))
        XCTAssertEqual(PrintSize("Round2x6"), .strip2x6)
        XCTAssertNil(PrintSize("4by6"))
        XCTAssertEqual(PrintSize.legacyMenu.count, 17)

        let strip = PrintSize.strip2x6.sheetPlan(copies: 3)
        XCTAssertEqual(strip.sheet, .photo4x6)
        XCTAssertEqual(strip.sheets, 2)
        XCTAssertEqual(strip.perSheet, 2)

        let photo = PrintSize.photo4x6.sheetPlan(copies: 3)
        XCTAssertEqual(photo.sheets, 3)
        XCTAssertEqual(photo.perSheet, 1)
        XCTAssertEqual(PrintSize.photo4x6.pixels().width, 1200)
    }

    func testMobileCarrierListMatchesShippedFormat() {
        let text = "AT&T, @mms.att.net, ATT.jpg\r\nUS Cellular, @mms.uscc.net, USCellular\nbroken line\n"
        let carriers = MobileCarrier.parseList(text)
        XCTAssertEqual(carriers.count, 2)
        XCTAssertEqual(carriers[0].gatewayDomain, "mms.att.net")
        XCTAssertEqual(carriers[0].address(forPhone: "+1 (555) 123-4567"), "5551234567@mms.att.net")
        XCTAssertNil(carriers[0].address(forPhone: "12345"))
    }

    func testLegacySettingsImport() {
        var settings = BoothSettings()
        let unknown = settings.applyLegacyValues([
            "NumPhotos": "3",
            "TimeSettings\\GetReadyDelay": "4",
            "Text/ReadyText": "Smile!",
            "BoothPin": "1234",
            "UseBoothPin": "0",
            "Output\\Email1\\Subject": "Your photos",
        ])
        XCTAssertEqual(settings.photosPerSession, 3)
        XCTAssertEqual(settings.timing.getReadyDelay, 4)
        XCTAssertEqual(settings.text.readyText, "Smile!")
        XCTAssertNil(settings.operatorPin)
        XCTAssertEqual(unknown, ["Output\\Email1\\Subject"])
    }

    func testLayoutsRoundTripAndCountPhotos() throws {
        for layout in PrintLayout.builtIn {
            let data = try JSONEncoder().encode(layout)
            XCTAssertEqual(try JSONDecoder().decode(PrintLayout.self, from: data), layout)
            for cell in layout.cells {
                XCTAssertGreaterThanOrEqual(cell.frame.x, 0)
                XCTAssertLessThanOrEqual(cell.frame.x + cell.frame.width, 1.0001)
                XCTAssertLessThanOrEqual(cell.frame.y + cell.frame.height, 1.0001)
            }
        }
        XCTAssertEqual(PrintLayout.strip(photos: 4).photoCount, 4)
        XCTAssertEqual(PrintLayout.grid4x6().photoCount, 4)
        XCTAssertEqual(RGBAColor(hex: "#FF000080")?.alpha ?? 0, 128.0 / 255, accuracy: 0.001)
        XCTAssertEqual(RGBAColor(hex: "00FF00")?.hex, "#00FF00")
    }

    func testCommandNamesMatchLegacySpelling() {
        XCTAssertEqual(BoothCommand(legacyName: " StartSession "), .startSession)
        XCTAssertEqual(BoothCommand(legacyName: "choosealternateprint"), .chooseAlternatePrint)
        XCTAssertNil(BoothCommand(legacyName: "snaplens"))
    }

    func testSessionLogWritesWindowsCompatibleTable() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("booth-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = try SessionLog(url: url)
        let summary = SessionSummary(result: .completed, photosTaken: 4, photoRetakes: 0, colorChoice: .sepia,
                                     printCopies: 2, stageReached: "End Instructions")
        try log.record(summary, startedAt: Date(), duration: 42, idle: 10, outputPath: "/tmp/print.jpg")
        XCTAssertEqual(try log.count(result: .completed), 1)
        XCTAssertEqual(try log.count(result: .cancelled), 0)
    }
}
