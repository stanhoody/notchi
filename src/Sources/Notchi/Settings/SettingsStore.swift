import SwiftUI
import ServiceManagement

/// Observable, persisted settings. Backed by UserDefaults (suite = standard, app is sandbox-free).
/// Views observe this directly; AppDelegate observes for window opacity / gate / fullscreen.
@MainActor
final class SettingsStore: ObservableObject {
    private let d = UserDefaults.standard
    private enum K {
        static let hideFS = "hideInFullscreen"
        static let hideVC = "hideOnVideoCalls"
        static let fps = "animationFPS"
        static let opacity = "opacity"
        static let creature = "creatureHex"
        static let autostart = "autostart"
        static let gate = "interceptPermissions"
        static let sound = "soundEnabled"
        static let skin = "skin"
        static let randomSkins = "randomSkins"
    }

    @Published var hideInFullscreen: Bool   { didSet { d.set(hideInFullscreen, forKey: K.hideFS) } }
    @Published var hideOnVideoCalls: Bool   { didSet { d.set(hideOnVideoCalls, forKey: K.hideVC) } }
    @Published var animationFPS: Double      { didSet { d.set(animationFPS, forKey: K.fps) } }   // 6...15
    @Published var opacity: Double           { didSet { d.set(opacity, forKey: K.opacity) } }     // 0.3...1
    @Published var creatureHex: String       { didSet { d.set(creatureHex, forKey: K.creature) } }
    @Published var interceptPermissions: Bool { didSet { d.set(interceptPermissions, forKey: K.gate) } }
    @Published var autostart: Bool           { didSet { d.set(autostart, forKey: K.autostart); applyAutostart() } }
    @Published var soundEnabled: Bool        { didSet { d.set(soundEnabled, forKey: K.sound) } }
    @Published var skin: String              { didSet { d.set(skin, forKey: K.skin) } }
    @Published var randomSkins: Bool         { didSet { d.set(randomSkins, forKey: K.randomSkins) } }

    init() {
        hideInFullscreen = d.object(forKey: K.hideFS) as? Bool ?? true
        hideOnVideoCalls = d.object(forKey: K.hideVC) as? Bool ?? false
        animationFPS = d.object(forKey: K.fps) as? Double ?? 10
        opacity = d.object(forKey: K.opacity) as? Double ?? 1.0
        creatureHex = d.object(forKey: K.creature) as? String ?? "#FF6A00"
        interceptPermissions = d.object(forKey: K.gate) as? Bool ?? false
        autostart = d.object(forKey: K.autostart) as? Bool ?? false
        soundEnabled = d.object(forKey: K.sound) as? Bool ?? false
        skin = d.object(forKey: K.skin) as? String ?? "claude"
        randomSkins = d.object(forKey: K.randomSkins) as? Bool ?? true
    }

    var creatureSkin: CreatureSkin { CreatureSkin(rawValue: skin) ?? .claude }
    static let skins: [CreatureSkin] = CreatureSkin.allCases

    /// Per-session character: a stable-per-session pick when "random" is on, else the chosen one.
    func skin(for sessionID: String) -> CreatureSkin {
        guard randomSkins else { return creatureSkin }
        let all = CreatureSkin.allCases
        return all[Self.stableHash(sessionID) % all.count]
    }

    /// FNV-1a — stable across launches (unlike String.hashValue).
    static func stableHash(_ s: String) -> Int {
        var h: UInt64 = 1469598103934665603
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return Int(h % 1_000_000)
    }

    var creatureColor: Color { Color(hex: creatureHex) }
    /// Multiplier applied to each animation's base fps (10 = 1.0×).
    var speed: Double { animationFPS / 10.0 }

    /// Preset creature colors offered in the picker.
    static let presets: [(name: String, hex: String)] = [
        ("orange", "#FF6A00"), ("lime", "#C6FF00"), ("cyan", "#00E5FF"),
        ("magenta", "#FF2D95"), ("yellow", "#FFEA00"), ("red", "#FF3B30"), ("white", "#FFFFFF"),
    ]

    private func applyAutostart() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if autostart { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            FileHandle.standardError.write(Data("[Notchi] autostart toggle failed: \(error)\n".utf8))
        }
    }
}

extension Color {
    /// `#RRGGBB` → Color. Falls back to orange on a bad string.
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        guard Scanner(string: s).scanHexInt64(&v), s.count == 6 else {
            self = Color(red: 1, green: 0x6A/255, blue: 0); return
        }
        self = Color(red: Double((v >> 16) & 0xFF) / 255,
                     green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255)
    }
}
