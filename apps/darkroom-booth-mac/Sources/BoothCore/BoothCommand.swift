import Foundation

/// Booth commands as named by the Windows app (Eventlib.dll). Inputs (keyboard,
/// Phidgets, RS-232 buttons, BoothControl web buttons) are bound to these names,
/// so `inputs.json` style configurations keep working.
public enum BoothCommand: String, Codable, CaseIterable, Sendable {
    case startSession = "startsession"
    case startVideo = "startvideo"
    case videoSession = "videosession"
    case burstSession = "burstsession"
    case cancelSession = "cancelsession"
    case reprintLast = "reprintlast"
    case printCopies = "printcopies"
    case choosePrimaryPrint = "chooseprimaryprint"
    case chooseAlternatePrint = "choosealternateprint"
    case chooseGraphic = "choosegraphic"
    case nextGraphic = "nextgraphic"
    case prevGraphic = "prevgraphic"
    case applyFilter = "applyfilter"
    case addCredit = "addcredit"
    case clearCredits = "clearcredits"
    case color = "color"
    case grayscale = "grayscale"
    case sepia = "sepia"
    case antique = "antique"
    case retro = "retro"
    // BoothControl "/controls" page actions; the wire names are ours.
    case retake = "retake"
    case takePhoto = "takephoto"

    /// Parses a command name case-insensitively, as the Windows app does.
    public init?(legacyName: String) {
        self.init(rawValue: legacyName.trimmingCharacters(in: .whitespaces).lowercased())
    }
}
