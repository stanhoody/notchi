import Foundation

/// Installs/removes Notchi's hook scripts into ~/.claude/hooks/notchi/ and patches
/// ~/.claude/settings.json with the REAL Claude Code nested hook schema:
///
///   { "hooks": { "PreToolUse": [ { "hooks": [ {"type":"command","command":"…"} ] } ] } }
///
/// Merges into existing arrays so other hooks (e.g. claude-sync-pull/push) are preserved.
/// Notchi entries are identified by a command path containing "/hooks/notchi/".
/// Idempotent: re-running replaces only Notchi's own entries. Honors $CLAUDE_CONFIG_DIR.
public enum HookInstaller {

    public struct Status: Sendable, Equatable {
        public let scriptsPresent: Bool
        public let settingsRegistered: Bool
        public let path: URL
    }

    public enum InstallError: Error, CustomStringConvertible {
        case settingsNotJSON(URL)
        case write(URL, underlying: String)
        public var description: String {
            switch self {
            case .settingsNotJSON(let u): return "settings file is not valid JSON: \(u.path)"
            case .write(let u, let e):    return "failed to write \(u.path): \(e)"
            }
        }
    }

    /// (hook event name, script filename) — multiple events share notchi-event.sh.
    private static let eventScript = "notchi-event.sh"
    private static let preToolUseScript = "notchi-pretooluse.sh"
    private static let registrations: [(event: String, script: String)] = [
        ("SessionStart", eventScript),
        ("SessionEnd",   eventScript),
        ("Stop",         eventScript),
        ("SubagentStop", eventScript),
        ("PostToolUse",  eventScript),
        ("Notification", eventScript),
        ("PreToolUse",   preToolUseScript),
    ]
    private static let notchiMarker = "/hooks/notchi/"

    // MARK: - Public API

    public static func status(configDir: URL = defaultConfigDir()) -> Status {
        let hooksDir = configDir.appendingPathComponent("hooks/notchi", isDirectory: true)
        let fm = FileManager.default
        let present = [eventScript, preToolUseScript].allSatisfy {
            fm.isExecutableFile(atPath: hooksDir.appendingPathComponent($0).path)
        }
        let registered = (try? settingsRegistered(configDir: configDir)) ?? false
        return Status(scriptsPresent: present, settingsRegistered: registered, path: hooksDir)
    }

    public static func install(configDir: URL = defaultConfigDir()) throws {
        try writeScripts(configDir: configDir)
        try patchSettings(configDir: configDir, register: true)
    }

    public static func uninstall(configDir: URL = defaultConfigDir()) throws {
        let hooksDir = configDir.appendingPathComponent("hooks/notchi", isDirectory: true)
        try? FileManager.default.removeItem(at: hooksDir)
        try patchSettings(configDir: configDir, register: false)
    }

    public static func defaultConfigDir() -> URL {
        if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")
    }

    // MARK: - Script files

    private static func hooksDir(_ configDir: URL) -> URL {
        configDir.appendingPathComponent("hooks/notchi", isDirectory: true)
    }

    private static func scriptPath(_ configDir: URL, _ name: String) -> String {
        hooksDir(configDir).appendingPathComponent(name).path
    }

    private static func writeScripts(configDir: URL) throws {
        let dir = hooksDir(configDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeIfChanged(HookScripts.eventScript, to: dir.appendingPathComponent(eventScript))
        try writeIfChanged(HookScripts.preToolUseScript, to: dir.appendingPathComponent(preToolUseScript))
    }

    private static func writeIfChanged(_ content: String, to url: URL) throws {
        let data = Data(content.utf8)
        if let existing = try? Data(contentsOf: url), existing == data {
            _ = chmod(url.path, 0o755)
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            _ = chmod(url.path, 0o755)
        } catch {
            throw InstallError.write(url, underlying: "\(error)")
        }
    }

    // MARK: - settings.json patch

    private static func settingsURL(_ configDir: URL) -> URL {
        configDir.appendingPathComponent("settings.json")
    }

    private static func loadSettings(configDir: URL) throws -> [String: Any] {
        let url = settingsURL(configDir)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallError.settingsNotJSON(url)
        }
        return obj
    }

    private static func writeSettings(_ obj: [String: Any], configDir: URL) throws {
        let url = settingsURL(configDir)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw InstallError.write(url, underlying: "\(error)")
        }
    }

    /// True when every Notchi event has an entry whose inner hooks reference our script.
    private static func settingsRegistered(configDir: URL) throws -> Bool {
        let settings = try loadSettings(configDir: configDir)
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        for (event, script) in registrations {
            let path = scriptPath(configDir, script)
            guard let entries = hooks[event] as? [[String: Any]] else { return false }
            let found = entries.contains { entry in
                entryReferences(entry, command: path)
            }
            if !found { return false }
        }
        return true
    }

    private static func patchSettings(configDir: URL, register: Bool) throws {
        var settings = (try? loadSettings(configDir: configDir)) ?? [:]
        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]

        for (event, script) in registrations {
            let path = scriptPath(configDir, script)
            var entries = (hooks[event] as? [[String: Any]]) ?? []
            // Drop any prior Notchi entry for this event (idempotent re-register / uninstall).
            entries.removeAll { entryIsNotchi($0) }
            if register {
                entries.append([
                    "hooks": [["type": "command", "command": path]]
                ])
            }
            if entries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = entries
            }
        }

        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }
        try writeSettings(settings, configDir: configDir)
    }

    /// True if a settings hook-entry's inner command list contains the exact path.
    private static func entryReferences(_ entry: [String: Any], command: String) -> Bool {
        guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
        return inner.contains { ($0["command"] as? String) == command }
    }

    /// True if any inner command of this entry points at our hooks/notchi/ dir.
    private static func entryIsNotchi(_ entry: [String: Any]) -> Bool {
        guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
        return inner.contains { (($0["command"] as? String) ?? "").contains(notchiMarker) }
    }
}
