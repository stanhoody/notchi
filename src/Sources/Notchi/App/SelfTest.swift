import Foundation
import Darwin

/// Lightweight self-check runnable without Xcode/XCTest (this machine has Command Line
/// Tools only). Run with `notchi --selftest`. Exercises the decoder, StateEngine
/// transitions, HookInstaller schema/merge, and a real socket round-trip.
enum SelfTest {
    private static var passed = 0
    private static var failed = 0

    static func run() async -> Int32 {
        decoder()
        await stateEngine()
        installer()
        await socketRoundTrip()

        let line = "\nSelfTest: \(passed) passed, \(failed) failed"
        FileHandle.standardError.write(Data((line + "\n").utf8))
        return failed == 0 ? 0 : 1
    }

    // MARK: checks

    private static func check(_ cond: Bool, _ name: String) {
        if cond { passed += 1 }
        else { failed += 1; FileHandle.standardError.write(Data("  FAIL: \(name)\n".utf8)) }
    }

    // MARK: socket round-trip (the layer teardown flagged as untested)

    private static func socketRoundTrip() async {
        let engine = StateEngine()
        let path = "/tmp/notchi-selftest-\(UUID().uuidString.prefix(8)).sock"
        let bridge = HookBridge(engine: engine, socketPath: path)
        do { try bridge.start() } catch { check(false, "socket: bridge start (\(error))"); return }
        defer { bridge.stop() }

        let ok1 = clientSend(path, #"{"hook_event_name":"SessionStart","session_id":"sx","cwd":"/Users/dev/code/x"}"#)
        check(ok1, "socket: client connected")
        try? await Task.sleep(nanoseconds: 250_000_000)
        check(await engine.state(for: "sx") == .idleWaiting, "socket: SessionStart → idleWaiting")

        _ = clientSend(path, #"{"hook_event_name":"PreToolUse","session_id":"sx","tool_name":"Read","tool_input":{"file_path":"/x"}}"#)
        try? await Task.sleep(nanoseconds: 250_000_000)
        check(await engine.state(for: "sx") == .working(.read), "socket: PreToolUse(Read) → working(read)")

        _ = clientSend(path, #"{"hook_event_name":"Stop","session_id":"sx"}"#)
        try? await Task.sleep(nanoseconds: 250_000_000)
        // Stop after work → celebrating (the happy-hop transient)
        check(await engine.state(for: "sx") == .celebrating, "socket: Stop → celebrating")
    }

    /// Minimal AF_UNIX client: connect, write one line, close (close → EOF → bridge reaps the FD).
    private static func clientSend(_ path: String, _ line: String) -> Bool {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let maxp = MemoryLayout.size(ofValue: addr.sun_path)
        if bytes.count >= maxp { return false }
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: maxp) { c in
                for (i, b) in bytes.enumerated() { c[i] = CChar(bitPattern: b) }
                c[bytes.count] = 0
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) }
        }
        if r != 0 { return false }
        var out = Array((line + "\n").utf8)
        _ = out.withUnsafeMutableBufferPointer { Darwin.write(fd, $0.baseAddress, $0.count) }
        return true
    }

    private static func decoder() {
        let start = #"{"hook_event_name":"SessionStart","session_id":"s","cwd":"/a","source":"startup"}"#
        if case .sessionStart(let p)? = HookLineDecoder.decode(start) {
            check(p.sessionID == "s" && p.cwd == "/a", "decode SessionStart")
        } else { check(false, "decode SessionStart") }

        let pre = #"{"hook_event_name":"PreToolUse","session_id":"s","tool_name":"Bash","tool_input":{"command":"ls -la"}}"#
        if case .preToolUse(let p)? = HookLineDecoder.decode(pre) {
            check(p.toolName == "Bash" && p.preview == "ls -la", "decode PreToolUse + preview")
        } else { check(false, "decode PreToolUse") }

        let transcript = #"{"type":"assistant","uuid":"x","sessionId":"s"}"#
        check(HookLineDecoder.decode(transcript) == nil, "transcript line ignored")

        check(HookLineDecoder.decode("garbage") == nil, "garbage ignored")
    }

    private static func stateEngine() async {
        let e = StateEngine()
        await e.apply(.sessionStarted(sessionID: "s1", cwd: "/Users/dev/code/notchi"))
        check(await e.state(for: "s1") == .idleWaiting, "start → idleWaiting")

        await e.apply(.toolStarted(sessionID: "s1", cwd: nil, tool: .bash))
        check(await e.state(for: "s1") == .working(.bash), "tool → working(bash)")

        await e.apply(.attention(sessionID: "s1", message: "hi"))
        check(await e.session(for: "s1")?.needsAttention == true, "notification → attention")

        await e.apply(.stopped(sessionID: "s1"))
        check(await e.state(for: "s1") == .celebrating, "stop after work → celebrate")
        check(await e.session(for: "s1")?.needsAttention == false, "stop clears attention")

        let req = PermissionRequest(id: "r1", tool: .edit, toolRawName: "Edit", preview: "/f")
        await e.apply(.permissionRequested(sessionID: "s1", request: req))
        check(await e.state(for: "s1") == .waitingPermission(req), "gate → waitingPermission")
        await e.apply(.userPermissionResponse(requestID: "r1", decision: .approve))
        check(await e.state(for: "s1") == .working(.edit), "approve → working(edit)")

        // tool error → confused
        await e.apply(.toolStarted(sessionID: "s2", cwd: "/x", tool: .bash))
        await e.apply(.toolFinished(sessionID: "s2", error: true))
        check(await e.state(for: "s2") == .confused, "tool error → confused")
        // plan tool maps to .plan kind
        check(ToolKind.from("TodoWrite") == .plan, "TodoWrite → plan")

        // gate timeout (walked-away prompt) reverts the zombie — no permanent waving
        let g = StateEngine()
        await g.apply(.sessionStarted(sessionID: "gz", cwd: "/x"))
        let greq = PermissionRequest(id: "gq", tool: .bash, toolRawName: "Bash", preview: "rm -rf x")
        await g.apply(.permissionRequested(sessionID: "gz", request: greq))
        check(await g.state(for: "gz") == .waitingPermission(greq), "gate → waitingPermission")
        await g.apply(.permissionTimedOut(requestID: "gq"))
        check(await g.state(for: "gz") == .idleWaiting, "gate timeout → idleWaiting (no zombie)")
        check(await g.consumePendingPermission(requestID: "gq") == nil, "gate timeout cleared pending")

        await e.apply(.sessionEnded(sessionID: "s1"))
        check(await e.state(for: "s1") == nil, "sessionEnd → evicted")

        let s = await e.session(for: "s1")
        check(s == nil, "evicted session gone")
    }

    private static func installer() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchi-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Seed an existing hook to verify merge.
        let existing: [String: Any] = ["hooks": ["SessionStart": [
            ["hooks": [["type": "command", "command": "$HOME/bin/claude-sync-pull.sh"]]]
        ]], "model": "opus"]
        if let data = try? JSONSerialization.data(withJSONObject: existing) {
            try? data.write(to: dir.appendingPathComponent("settings.json"))
        }

        do {
            try HookInstaller.install(configDir: dir)
            try HookInstaller.install(configDir: dir)   // idempotent
        } catch {
            check(false, "install threw: \(error)")
            return
        }

        let url = dir.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = obj["hooks"] as? [String: Any]
        else { check(false, "settings readable"); return }

        check(obj["model"] as? String == "opus", "preserved unrelated key")

        let starts = (hooks["SessionStart"] as? [[String: Any]]) ?? []
        let cmds = starts.compactMap { ($0["hooks"] as? [[String: Any]])?.first?["command"] as? String }
        check(cmds.contains { $0.contains("claude-sync-pull.sh") }, "preserved existing SessionStart hook")
        check(cmds.contains { $0.contains("notchi-event.sh") }, "added Notchi SessionStart hook")

        let pre = (hooks["PreToolUse"] as? [[String: Any]]) ?? []
        check(pre.count == 1, "idempotent: single PreToolUse entry")
        let inner = (pre.first?["hooks"] as? [[String: Any]])?.first
        check(inner?["type"] as? String == "command", "nested schema type=command")
        check((inner?["command"] as? String)?.hasSuffix("notchi-pretooluse.sh") == true, "nested schema command path")

        check(HookInstaller.status(configDir: dir).settingsRegistered, "status registered")

        try? HookInstaller.uninstall(configDir: dir)
        let after = (try? Data(contentsOf: url)).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        } ?? [:]
        let afterHooks = (after["hooks"] as? [String: Any]) ?? [:]
        let afterStarts = (afterHooks["SessionStart"] as? [[String: Any]]) ?? []
        let afterCmds = afterStarts.compactMap { ($0["hooks"] as? [[String: Any]])?.first?["command"] as? String }
        check(afterCmds.contains { $0.contains("claude-sync-pull.sh") }, "uninstall preserved existing hook")
        check(!afterCmds.contains { $0.contains("notchi") }, "uninstall removed Notchi")
        check(afterHooks["PreToolUse"] == nil, "uninstall removed Notchi-only PreToolUse key")
    }
}
