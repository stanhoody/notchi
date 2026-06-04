import AppKit
import Darwin
import Foundation

/// Resolves a Claude Code session_id to the OS process that hosts it, via
/// `~/.claude/sessions/<PID>.json` (which maps sessionId → pid, cwd, entrypoint).
/// Used to focus the RIGHT host when the user taps a creature:
/// - entrypoint "claude-desktop" → activate the Claude desktop app (per-tab focus isn't
///   exposed by the app, so this is the honest ceiling)
/// - a terminal entrypoint → walk the PID parent chain to the hosting terminal and raise it
public struct SessionRecord: Sendable, Equatable {
    public let pid: pid_t
    public let sessionID: String
    public let cwd: String
    public let entrypoint: String
    public var isDesktop: Bool { entrypoint == "claude-desktop" }
}

public enum SessionLocator {

    public static func find(sessionID sid: String, configDir: URL = defaultConfigDir()) -> SessionRecord? {
        let dir = configDir.appendingPathComponent("sessions", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return nil }
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let s = obj["sessionId"] as? String, s == sid
            else { continue }
            let pid = pid_t((obj["pid"] as? Int) ?? -1)
            return SessionRecord(pid: pid,
                                 sessionID: s,
                                 cwd: obj["cwd"] as? String ?? "",
                                 entrypoint: obj["entrypoint"] as? String ?? "")
        }
        return nil
    }

    public static func defaultConfigDir() -> URL {
        if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")
    }

    /// Parent pid via sysctl (reliable, no libproc struct dependencies).
    public static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let r = mib.withUnsafeMutableBufferPointer { mibPtr in
            sysctl(mibPtr.baseAddress, u_int(mibPtr.count), &info, &size, nil, 0)
        }
        if r != 0 || size == 0 { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }

    /// Walk the pid's ancestry; return the first ancestor whose bundle id is in `bundleIDs`.
    public static func ancestorApp(of pid: pid_t, matching bundleIDs: [String]) -> NSRunningApplication? {
        var current: pid_t? = pid
        var hops = 0
        while let p = current, p > 1, hops < 16 {
            if let app = NSRunningApplication(processIdentifier: p),
               let bid = app.bundleIdentifier, bundleIDs.contains(bid) {
                return app
            }
            current = parentPID(of: p)
            hops += 1
        }
        return nil
    }
}
