import Foundation

/// When the countdown runs ("Timing" page of the Windows Booth Options).
public enum CountdownMode: String, Codable, Sendable {
    case none
    case firstPhotoOnly
    case eachPhoto
}

/// What live view does while a photo is captured ("Liveview" page).
public enum LiveViewCaptureMode: String, Codable, Sendable {
    case continueWithoutPause
    case pauseToCapture
}

/// Timing values in seconds. Names follow the `TimeSettings\*` keys of the
/// Windows app so imported settings map one to one.
public struct BoothTiming: Codable, Equatable, Sendable {
    public var attractDelay: Double = 0
    public var getReadyDelay: Double = 2
    public var firstPhotoCountdown: Int = 5
    public var countdown: Int = 3
    public var nextPhotoDelay: Double = 2
    public var liveviewPause: Double = 1
    public var lastPhotoDelay: Double = 1
    public var endTextDelay: Double = 5
    public var reviewDelay: Double = 4
    public var copiesPromptDelay: Double = 10

    public init() {}
}

/// On-screen text (`Text\*` keys) with the Windows app's defaults.
public struct BoothText: Codable, Equatable, Sendable {
    public var startText = "Touch the screen to start"
    public var readyText = "Get Ready!"
    public var endText = "Thank you.  Please pick up your photos outside the booth."
    public var reviewText = "Here's your photo!"
    public var copiesPromptText = "How many copies would you like?"
    public var emailPromptText = "Would you like the photo sent to you?"
    public var maintenanceText = "Booth Maintenance required. Please alert the booth operator."

    public init() {}
}

/// Event-level booth settings. This is the macOS app's own JSON document; the
/// `legacyKey` mapping documents where each value lives in the Windows app.
public struct BoothSettings: Codable, Equatable, Sendable {
    public var settingsVersion = 1
    /// `NumPhotos`. 0 means a video-only booth in the Windows app.
    public var photosPerSession = 4
    public var countdownMode: CountdownMode = .eachPhoto
    public var liveViewEnabled = true
    public var liveViewCaptureMode: LiveViewCaptureMode = .pauseToCapture
    public var mirrorLiveView = true
    /// `ReviewPhoto\Enabled`.
    public var reviewEnabled = true
    /// `MaxRetakes`. Retakes offered per photo after a failed capture or on request.
    public var maxRetakes = 1
    /// `PrintCopies`.
    public var printCopies = 1
    /// `CopiesPrompt`: ask the guest how many copies (bounded by maxCopies).
    public var copiesPrompt = false
    public var maxCopies = 4
    public var printEnabled = true
    /// `DefaultColorEffect`.
    public var defaultColorEffect: ColorEffect = .color
    /// `KeepLastEffect`.
    public var keepLastEffect = false
    /// `UseBoothPin` / `BoothPin` (operator PIN to leave booth mode).
    public var operatorPin: String?
    /// `Credits\RequireStartup` / `Credits\StartupMin`.
    public var creditsRequiredToStart = 0
    public var timing = BoothTiming()
    public var text = BoothText()

    public init() {}

    public func countdownSeconds(beforePhoto index: Int) -> Int {
        switch countdownMode {
        case .none: return 0
        case .firstPhotoOnly: return index == 1 ? timing.firstPhotoCountdown : 0
        case .eachPhoto: return index == 1 ? timing.firstPhotoCountdown : timing.countdown
        }
    }
}

extension BoothSettings {
    /// Applies values from the Windows app's flat `Key\Sub` namespace. Unknown
    /// keys are returned so callers can report what was not imported.
    @discardableResult
    public mutating func applyLegacyValues(_ values: [String: String]) -> [String] {
        var unknown: [String] = []
        for (rawKey, value) in values {
            let key = rawKey.replacingOccurrences(of: "/", with: "\\")
            switch key {
            case "NumPhotos": if let v = Int(value) { photosPerSession = v }
            case "PrintCopies": if let v = Int(value) { printCopies = max(1, v) }
            case "CopiesPrompt": copiesPrompt = Self.bool(value)
            case "KeepLastEffect": keepLastEffect = Self.bool(value)
            case "UseBoothPin": continue
            case "BoothPin": operatorPin = value.isEmpty ? nil : value
            case "ReviewPhoto\\Enabled": reviewEnabled = Self.bool(value)
            case "ReviewPhoto\\Text": text.reviewText = value
            case "ReviewPhoto\\Delay": if let v = Double(value) { timing.reviewDelay = v }
            case "MaxRetakes": if let v = Int(value) { maxRetakes = v }
            case "Credits\\StartupMin": if let v = Int(value) { creditsRequiredToStart = v }
            case "TimeSettings\\AttractDelay": if let v = Double(value) { timing.attractDelay = v }
            case "TimeSettings\\GetReadyDelay": if let v = Double(value) { timing.getReadyDelay = v }
            case "TimeSettings\\FirstPhotoCountdown": if let v = Int(value) { timing.firstPhotoCountdown = v }
            case "TimeSettings\\NextPhotoDelay": if let v = Double(value) { timing.nextPhotoDelay = v }
            case "TimeSettings\\LiveviewPause": if let v = Double(value) { timing.liveviewPause = v }
            case "TimeSettings\\LastPhotoDelay": if let v = Double(value) { timing.lastPhotoDelay = v }
            case "TimeSettings\\EndTextDelay": if let v = Double(value) { timing.endTextDelay = v }
            case "TimeSettings\\CopiesPromptDelay": if let v = Double(value) { timing.copiesPromptDelay = v }
            case "Text\\StartText": text.startText = value
            case "Text\\ReadyText": text.readyText = value
            case "Text\\EndText": text.endText = value
            case "Text\\CopiesPromptText": text.copiesPromptText = value
            case "Text\\EmailPromptText": text.emailPromptText = value
            default: unknown.append(rawKey)
            }
        }
        // Dictionary order is unspecified, so the PIN switch is applied last.
        if let use = values["UseBoothPin"], !Self.bool(use) { operatorPin = nil }
        return unknown.sorted()
    }

    private static func bool(_ value: String) -> Bool {
        switch value.lowercased() {
        case "1", "true", "yes", "on": return true
        default: return false
        }
    }
}
