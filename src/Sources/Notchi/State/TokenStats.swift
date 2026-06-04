import Foundation

/// Best-effort token + model extraction from a session's JSONL transcript.
///
/// Honest by design: on this Claude Code build the `usage` field is usually null and there is
/// no local cost store, so token counts are often unavailable. We return what we can find and
/// the UI shows "—" otherwise — never a fabricated number.
public struct TokenStats: Sendable {
    public var model: String?
    public var input: Int?
    public var output: Int?
    public var cacheRead: Int?
    public var cacheWrite: Int?
    /// Human-readable session title — Claude's auto `summary` if present, else the first
    /// user prompt (truncated). Used as the "chat name" in the island.
    public var title: String?

    public var hasTokens: Bool { input != nil || output != nil || cacheRead != nil || cacheWrite != nil }

    /// Approximate USD cost from token counts × bundled pricing. nil when no counts/pricing.
    public func dollars(pricing: [String: ModelPrice]) -> Double? {
        guard hasTokens, let model, let p = ModelPrice.match(model, in: pricing) else { return nil }
        let mIn = Double(input ?? 0) / 1_000_000 * p.input
        let mOut = Double(output ?? 0) / 1_000_000 * p.output
        let mCR = Double(cacheRead ?? 0) / 1_000_000 * p.cacheRead
        let mCW = Double(cacheWrite ?? 0) / 1_000_000 * p.cacheWrite
        return mIn + mOut + mCR + mCW
    }

    /// Reads the transcript for a session, reconstructing its path from cwd + sessionID
    /// (Claude convention: ~/.claude/projects/<cwd with / and . as ->/<sessionID>.jsonl).
    /// Tails the last ~1MB to stay cheap on large transcripts.
    public static func read(cwd: String, sessionID: String,
                            configDir: URL = HookInstaller.defaultConfigDir()) -> TokenStats {
        var stats = TokenStats()
        guard let url = transcriptURL(cwd: cwd, sessionID: sessionID, configDir: configDir) else {
            return stats
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return stats }
        defer { try? handle.close() }

        let end = (try? handle.seekToEnd()) ?? 0

        // Title: read a head chunk (summary / first user prompt lives near the top).
        try? handle.seek(toOffset: 0)
        if let head = try? handle.read(upToCount: 262_144), let htext = String(data: head, encoding: .utf8) {
            stats.title = extractTitle(from: htext)
        }

        // Tokens + model: tail the last ~1MB.
        let window: UInt64 = 1_000_000
        let start = end > window ? end - window : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else {
            return stats
        }
        accumulate(text, into: &stats)
        return stats
    }

    public enum Window: Sendable { case today, fiveHour }

    /// Sum tokens across ALL session transcripts touched within the window (best-effort: filters
    /// files by modification time, sums their usage). Approximate but honest — shows "—" when no
    /// usage is recorded. Run off the main thread; tails each file to stay cheap.
    public static func aggregate(window: Window,
                                 configDir: URL = HookInstaller.defaultConfigDir()) -> TokenStats {
        var stats = TokenStats()
        let cutoff: Date = window == .today
            ? Calendar.current.startOfDay(for: Date())
            : Date().addingTimeInterval(-5 * 3600)
        let projects = configDir.appendingPathComponent("projects", isDirectory: true)
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else {
            return stats
        }
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(at: dir,
                                  includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for f in files where f.pathExtension == "jsonl" {
                let mod = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                guard let mod, mod >= cutoff else { continue }
                guard let h = try? FileHandle(forReadingFrom: f) else { continue }
                defer { try? h.close() }
                let end = (try? h.seekToEnd()) ?? 0
                let win: UInt64 = 1_000_000
                try? h.seek(toOffset: end > win ? end - win : 0)
                if let d = try? h.readToEnd(), let t = String(data: d, encoding: .utf8) {
                    accumulate(t, into: &stats)
                }
            }
        }
        return stats
    }

    /// Parse newline JSON, summing usage and capturing the model.
    private static func accumulate(_ text: String, into stats: inout TokenStats) {
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            let message = obj["message"] as? [String: Any]
            if let m = (obj["model"] as? String) ?? (message?["model"] as? String) { stats.model = m }
            let usage = (obj["usage"] as? [String: Any]) ?? (message?["usage"] as? [String: Any])
            if let u = usage {
                stats.input     = add(stats.input, u["input_tokens"] as? Int)
                stats.output    = add(stats.output, u["output_tokens"] as? Int)
                stats.cacheRead = add(stats.cacheRead, u["cache_read_input_tokens"] as? Int)
                stats.cacheWrite = add(stats.cacheWrite, u["cache_creation_input_tokens"] as? Int)
            }
        }
    }

    private static func add(_ a: Int?, _ b: Int?) -> Int? {
        guard let b else { return a }
        return (a ?? 0) + b
    }

    /// Prefer Claude's auto `summary`; else the first real user prompt. Truncated to ~48 chars.
    private static func extractTitle(from headText: String) -> String? {
        var firstPrompt: String?
        for line in headText.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            if let s = obj["summary"] as? String, !s.isEmpty { return trim(s) }
            if firstPrompt == nil, (obj["type"] as? String) == "user" {
                if let c = obj["content"] as? String { firstPrompt = c }
                else if let msg = obj["message"] as? [String: Any], let c = msg["content"] as? String { firstPrompt = c }
            }
        }
        return firstPrompt.map(trim)
    }

    private static func trim(_ s: String) -> String {
        let oneLine = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return oneLine.count > 48 ? String(oneLine.prefix(48)) + "…" : oneLine
    }

    private static func transcriptURL(cwd: String, sessionID: String, configDir: URL) -> URL? {
        let projects = configDir.appendingPathComponent("projects", isDirectory: true)
        let candidates = [
            cwd.replacingOccurrences(of: "/", with: "-"),
            cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        ]
        for enc in candidates {
            let url = projects.appendingPathComponent(enc, isDirectory: true)
                .appendingPathComponent("\(sessionID).jsonl")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}

/// Per-model price per 1M tokens (USD). Bundled, best-effort; update on model releases.
public struct ModelPrice: Sendable {
    public let input: Double
    public let output: Double
    public let cacheRead: Double
    public let cacheWrite: Double

    /// Rough public list prices (USD / 1M tokens) as of early 2026. Used only when the
    /// transcript actually carries token counts.
    public static let table: [String: ModelPrice] = [
        "opus":   ModelPrice(input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75),
        "sonnet": ModelPrice(input: 3,  output: 15, cacheRead: 0.3, cacheWrite: 3.75),
        "haiku":  ModelPrice(input: 0.8, output: 4, cacheRead: 0.08, cacheWrite: 1.0),
    ]

    /// Loose substring match against the model id (e.g. "claude-opus-4-8" → opus).
    static func match(_ model: String, in pricing: [String: ModelPrice]) -> ModelPrice? {
        let lower = model.lowercased()
        for (key, price) in pricing where lower.contains(key) { return price }
        return nil
    }
}
