import Foundation

/// Guest-selectable colour modes (Ctrl+C/B/S hotkeys and colour booth commands).
public enum ColorEffect: String, Codable, CaseIterable, Sendable {
    case color
    case grayscale
    case sepia
    case antique
    case retro

    public init?(command: BoothCommand) {
        switch command {
        case .color: self = .color
        case .grayscale: self = .grayscale
        case .sepia: self = .sepia
        case .antique: self = .antique
        case .retro: self = .retro
        default: return nil
        }
    }
}
