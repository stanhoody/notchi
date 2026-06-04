import SwiftUI

/// Contents of the menu-bar settings popover. Controls bind directly to SettingsStore
/// (hot-reloaded by the app); hooks + quit are callbacks into AppDelegate.
struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    var hooksInstalled: Bool
    var onInstallHooks: () -> Void
    var onUninstallHooks: () -> Void
    var onQuit: () -> Void

    var body: some View {
        // Scrolls inside the fixed-size popover (set in AppDelegate) so a tall list never
        // runs off the top of the screen.
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                SpriteView(state: .working(.edit), skin: settings.creatureSkin, pixel: 2,
                           accentColor: settings.creatureColor)
                    .frame(width: 48, height: 36)
                Text("Notchi").font(.system(size: 15, weight: .bold, design: .rounded))
                Spacer()
            }

            Divider()

            Toggle("Hide in fullscreen", isOn: $settings.hideInFullscreen)
            Toggle("Hide on video calls", isOn: $settings.hideOnVideoCalls)
            Toggle("Launch at login", isOn: $settings.autostart)
            Toggle("Sound on attention / done", isOn: $settings.soundEnabled)
            Toggle("Confirm every non-allowlisted tool (advanced)", isOn: $settings.interceptPermissions)
                .help("OFF (default): the island appears only when Claude actually pings you (its Notification) — answer in Claude. ON: Notchi holds every non-read, non-allowlisted tool for Approve/Deny in the notch (asks more).")

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Random character per session", isOn: $settings.randomSkins)
                    .help("On: every Claude session gets a different character. Off: all use the one you pick below.")
                Text(settings.randomSkins ? "Characters (random per session)" : "Your character")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(SettingsStore.skins, id: \.self) { sk in
                        let selected = !settings.randomSkins && settings.creatureSkin == sk
                        VStack(spacing: 1) {
                            SpriteView(state: .idle, skin: sk, pixel: 1.5, accentColor: settings.creatureColor)
                                .frame(width: 40, height: 30)
                            Text(sk.display).font(.system(size: 8)).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(selected ? Color.primary.opacity(0.12) : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(selected ? Color.primary.opacity(0.5) : .clear, lineWidth: 1))
                        .contentShape(Rectangle())
                        .onTapGesture { settings.randomSkins = false; settings.skin = sk.rawValue }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Animation speed  \(Int(settings.animationFPS)) fps")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Slider(value: $settings.animationFPS, in: 6...15, step: 1)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Opacity  \(Int(settings.opacity * 100))%")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Slider(value: $settings.opacity, in: 0.3...1.0, step: 0.05)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Color").font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(SettingsStore.presets, id: \.hex) { preset in
                        Circle()
                            .fill(Color(hex: preset.hex))
                            .frame(width: 18, height: 18)
                            .overlay(
                                Circle().strokeBorder(
                                    settings.creatureHex.caseInsensitiveCompare(preset.hex) == .orderedSame
                                        ? Color.primary : Color.primary.opacity(0.15),
                                    lineWidth: settings.creatureHex.caseInsensitiveCompare(preset.hex) == .orderedSame ? 2 : 1)
                            )
                            .onTapGesture { settings.creatureHex = preset.hex }
                    }
                }
            }

            Divider()

            HStack {
                Circle().fill(hooksInstalled ? Color.green : Color.orange).frame(width: 8, height: 8)
                Text(hooksInstalled ? "Hooks installed" : "Hooks not installed")
                    .font(.system(size: 12))
                Spacer()
            }
            HStack(spacing: 8) {
                pill(hooksInstalled ? "Reinstall hooks" : "Install hooks", action: onInstallHooks)
                if hooksInstalled { pill("Uninstall", action: onUninstallHooks) }
            }

            Divider()

            pill("Quit Notchi", action: onQuit)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 280)
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }
}
