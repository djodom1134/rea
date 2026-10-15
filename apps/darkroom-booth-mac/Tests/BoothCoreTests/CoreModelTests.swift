@testable import BoothCore
import Testing

@Suite struct CoreModelTests {
    @Test func testTemplateVariablesReplaceKnownAndKeepUnknown() {
        let vars = TemplateVariables(["EventName": "Smith Wedding"])
        #expect(vars.replacing(in: "%EventName% - %Unknown% 100%%") == "Smith Wedding - %Unknown% 100%")
        #expect(vars.replacing(in: "%eventname%") == "Smith Wedding")
        #expect(vars.replacing(in: "50% off") == "50% off")
    }

    @Test func testStandardVariablesIncludeTime24() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13 UTC
        let vars = TemplateVariables.standard(eventName: "E", eventDate: date, now: date, calendar: calendar,
                                              locale: Locale(identifier: "en_US"))
        #expect(vars.values["Time24"] == "22:13")
        #expect(vars.values["EventName"] == "E")
    }

    @Test func testPrintSizeParsingAndStripPlan() {
        #expect(PrintSize("6x2") == PrintSize(width: 2, height: 6))
        #expect(PrintSize("Round2x6") == .strip2x6)
        #expect(PrintSize("4by6") == nil)
        #expect(PrintSize.legacyMenu.count == 17)

        let strip = PrintSize.strip2x6.sheetPlan(copies: 3)
        #expect(strip.sheet == .photo4x6)
        #expect(strip.sheets == 2)
        #expect(strip.perSheet == 2)

        let photo = PrintSize.photo4x6.sheetPlan(copies: 3)
        #expect(photo.sheets == 3)
        #expect(photo.perSheet == 1)
        #expect(PrintSize.photo4x6.pixels().width == 1200)
    }

    @Test func testMobileCarrierListMatchesShippedFormat() {
        let text = "AT&T, @mms.att.net, ATT.jpg\r\nUS Cellular, @mms.uscc.net, USCellular\nbroken line\n"
        let carriers = MobileCarrier.parseList(text)
        #expect(carriers.count == 2)
        #expect(carriers[0].gatewayDomain == "mms.att.net")
        #expect(carriers[0].address(forPhone: "+1 (555) 123-4567") == "5551234567@mms.att.net")
        #expect(carriers[0].address(forPhone: "12345") == nil)
    }

    @Test func testLegacySettingsImport() {
        var settings = BoothSettings()
        let unknown = settings.applyLegacyValues([
            "NumPhotos": "3",
            "TimeSettings\\GetReadyDelay": "4",
            "Text/ReadyText": "Smile!",
            "BoothPin": "1234",
            "UseBoothPin": "0",
            "Output\\Email1\\Subject": "Your photos",
        ])
        #expect(settings.photosPerSession == 3)
        #expect(settings.timing.getReadyDelay == 4)
        #expect(settings.text.readyText == "Smile!")
        #expect(settings.operatorPin == nil)
        #expect(unknown == ["Output\\Email1\\Subject"])
    }

    @Test func testLayoutsRoundTripAndCountPhotos() throws {
        for layout in PrintLayout.builtIn {
            let data = try JSONEncoder().encode(layout)
            #expect(try JSONDecoder().decode(PrintLayout.self, from: data) == layout)
            for cell in layout.cells {
                #expect(cell.frame.x >= 0)
                #expect(cell.frame.x + cell.frame.width <= 1.0001)
                #expect(cell.frame.y + cell.frame.height <= 1.0001)
            }
        }
        #expect(PrintLayout.strip(photos: 4).photoCount == 4)
        #expect(PrintLayout.grid4x6().photoCount == 4)
        #expect(abs((RGBAColor(hex: "#FF000080")?.alpha ?? 0) - (128.0 / 255)) <= 0.001)
        #expect(RGBAColor(hex: "00FF00")?.hex == "#00FF00")
    }

    @Test func testCommandNamesMatchLegacySpelling() {
        #expect(BoothCommand(legacyName: " StartSession ") == .startSession)
        #expect(BoothCommand(legacyName: "choosealternateprint") == .chooseAlternatePrint)
        #expect(BoothCommand(legacyName: "snaplens") == nil)
    }

    @Test func testSessionLogWritesWindowsCompatibleTable() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("booth-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = try SessionLog(url: url)
        let summary = SessionSummary(result: .completed, photosTaken: 4, photoRetakes: 0, colorChoice: .sepia,
                                     printCopies: 2, stageReached: "End Instructions")
        try log.record(summary, startedAt: Date(), duration: 42, idle: 10, outputPath: "/tmp/print.jpg")
        #expect(try log.count(result: .completed) == 1)
        #expect(try log.count(result: .cancelled) == 0)
    }
}
