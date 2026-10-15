import BoothCore
import Foundation

/// Keyboard shortcuts from the Windows booth: Space/Enter start a session,
/// Ctrl+C/B/S pick colour/black-and-white/sepia, Ctrl+R reprints the last
/// output. (Ctrl+T test mode and Alt+key bindings are not ported yet.)
public enum KeyBindings {
    public static func command(for key: String, control: Bool) -> BoothCommand? {
        switch (key.lowercased(), control) {
        case (" ", false), ("\r", false), ("\n", false): return .startSession
        case ("c", true): return .color
        case ("b", true): return .grayscale
        case ("s", true): return .sepia
        case ("r", true): return .reprintLast
        default: return nil
        }
    }
}
