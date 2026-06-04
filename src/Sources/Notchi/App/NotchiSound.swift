import AppKit

/// Tiny wrapper over macOS system sounds (borrowed idea: pixel-agents' optional chimes).
/// Off by default; gated by the settings toggle at the call site.
enum NotchiSound {
    static func play(_ name: String) {
        NSSound(named: NSSound.Name(name))?.play()
    }
    static let needsYou = "Glass"   // attention / permission
    static let done = "Tink"        // finished a turn
}
