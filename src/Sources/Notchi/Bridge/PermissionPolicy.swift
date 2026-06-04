import Darwin
import Foundation

/// Decides whether a tool would make Claude Code ASK for permission — i.e. whether Notchi
/// should hold it and show Approve/Deny. Mirrors Claude's behaviour: read-only tools and
/// allowlisted rules pass silently; everything else (Bash, Edit, Write, WebFetch, MCP, …)
/// is what Claude would prompt for, so that's when we show the buttons.
///
/// Reads `permissions.{allow,deny,defaultMode}` from user + project settings, cached briefly.
enum PermissionPolicy {

    /// Tools Claude never prompts for (safe, read-only) — never gated.
    private static let builtinSafe: Set<String> = [
        "Read", "Glob", "Grep", "LS", "TodoWrite", "NotebookRead", "Task"
    ]

    struct Config {
        var allow: [String] = []
        var deny: [String] = []
        var defaultMode: String?
    }

    private struct Cached { let config: Config; let at: Date }
    private static var cache: [String: Cached] = [:]
    private static let cacheLock = NSLock()
    private static let ttl: TimeInterval = 3

    /// True when Claude would prompt for this tool → Notchi should gate + show buttons.
    static func shouldGate(toolName: String, toolInput: [String: AnyCodable],
                           cwd: String, configDir: URL) -> Bool {
        if builtinSafe.contains(toolName) { return false }
        let cfg = config(cwd: cwd, configDir: configDir)
        if cfg.defaultMode == "bypassPermissions" { return false }

        let arg = primaryArg(toolName: toolName, input: toolInput)
        // Explicit deny → Claude blocks it itself; nothing for us to confirm.
        if cfg.deny.contains(where: { matches(rule: $0, tool: toolName, arg: arg) }) { return false }
        // Explicit allow → auto-allowed, no prompt.
        if cfg.allow.contains(where: { matches(rule: $0, tool: toolName, arg: arg) }) { return false }
        // Otherwise Claude would prompt → gate.
        return true
    }

    // MARK: - Config loading (cached)

    private static func config(cwd: String, configDir: URL) -> Config {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let c = cache[cwd], Date().timeIntervalSince(c.at) < ttl { return c.config }
        var merged = Config()
        // User settings, then project settings (project can add more allows).
        for url in settingsURLs(cwd: cwd, configDir: configDir) {
            guard let perms = readPermissions(url) else { continue }
            merged.allow += perms.allow
            merged.deny += perms.deny
            if merged.defaultMode == nil { merged.defaultMode = perms.defaultMode }
        }
        cache[cwd] = Cached(config: merged, at: Date())
        return merged
    }

    private static func settingsURLs(cwd: String, configDir: URL) -> [URL] {
        var urls = [
            configDir.appendingPathComponent("settings.json"),
            configDir.appendingPathComponent("settings.local.json"),
        ]
        if !cwd.isEmpty {
            let proj = URL(fileURLWithPath: cwd).appendingPathComponent(".claude")
            urls.append(proj.appendingPathComponent("settings.json"))
            urls.append(proj.appendingPathComponent("settings.local.json"))
        }
        return urls
    }

    private static func readPermissions(_ url: URL) -> Config? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let perms = obj["permissions"] as? [String: Any] else { return nil }
        return Config(
            allow: (perms["allow"] as? [String]) ?? [],
            deny: (perms["deny"] as? [String]) ?? [],
            defaultMode: perms["defaultMode"] as? String
        )
    }

    // MARK: - Rule matching

    private static func primaryArg(toolName: String, input: [String: AnyCodable]) -> String {
        func s(_ k: String) -> String? { input[k]?.value as? String }
        switch toolName {
        case "Bash":                                     return s("command") ?? ""
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return s("file_path") ?? ""
        case "Read", "Glob", "Grep":                     return s("file_path") ?? s("path") ?? s("pattern") ?? ""
        case "WebFetch", "WebSearch":                    return s("url") ?? s("query") ?? ""
        default:                                          return input.values.compactMap { $0.value as? String }.first ?? ""
        }
    }

    /// Match a settings rule (`"Tool"` or `"Tool(pattern)"`) against a tool + its primary arg.
    private static func matches(rule: String, tool: String, arg: String) -> Bool {
        guard let open = rule.firstIndex(of: "(") else {
            return rule == tool                          // bare tool name → matches any use
        }
        let ruleTool = String(rule[rule.startIndex..<open])
        guard ruleTool == tool, rule.hasSuffix(")") else { return false }
        let inner = String(rule[rule.index(after: open)..<rule.index(before: rule.endIndex)])
        return argMatches(pattern: inner, arg: arg)
    }

    private static func argMatches(pattern: String, arg: String) -> Bool {
        if pattern.isEmpty || pattern == "*" { return true }
        // Claude's "prefix:*" syntax (e.g. Bash(npm run test:*)).
        if let r = pattern.range(of: ":*", options: .backwards), pattern.distance(from: r.upperBound, to: pattern.endIndex) == 0 {
            let prefix = String(pattern[pattern.startIndex..<r.lowerBound])
            return arg.hasPrefix(prefix)
        }
        if pattern.contains("*") || pattern.contains("?") || pattern.contains("[") {
            return fnmatch(pattern, arg, 0) == 0
        }
        // Exact, or a prefix that ends on a real boundary — so `Bash(git)` matches `git status`
        // but NOT `gitfoo`, and `Edit(/a/safe)` matches `/a/safe/x` but NOT `/a/safe-evil`.
        if arg == pattern { return true }
        if arg.hasPrefix(pattern) {
            let next = arg[arg.index(arg.startIndex, offsetBy: pattern.count)]
            return next == "/" || next == " " || next == ":"
        }
        return false
    }
}
