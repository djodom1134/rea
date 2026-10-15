import Foundation

/// Booth stages recovered from the Windows app's stage labels and
/// "Booth Object Visibility" choices (Eventlib.dll / DarkroomBooth.exe strings).
/// Screen templates show or hide objects per stage, so the identifiers are
/// part of the template contract.
public enum BoothStage: Hashable, Codable, Sendable {
    case attract
    case startSession
    case getReady
    case beforePhoto(Int)
    case countdown(remaining: Int, photo: Int)
    case takePhoto(Int)
    case afterPhoto(Int)
    case afterLastPhoto
    case review
    case processing
    case copiesPrompt
    case endInstructions
    case outOfService(reason: String)

    /// The label the Windows app uses for this stage, for template visibility.
    public var legacyLabel: String {
        switch self {
        case .attract: return "Attract Mode"
        case .startSession: return "Start Session"
        case .getReady: return "Photo Session"
        case .beforePhoto(let n): return "Before Photo \(n)"
        case .countdown(let remaining, _): return "Countdown \(remaining)"
        case .takePhoto: return "Photo Session"
        case .afterPhoto(let n): return "After Photo \(n)"
        case .afterLastPhoto: return "After Last Photo"
        case .review: return "After Last Photo"
        case .processing: return "After Last Photo"
        case .copiesPrompt: return "After Last Photo"
        case .endInstructions: return "End Instructions"
        case .outOfService: return "Attract Mode"
        }
    }

    public var isInSession: Bool {
        switch self {
        case .attract, .outOfService: return false
        default: return true
        }
    }
}
