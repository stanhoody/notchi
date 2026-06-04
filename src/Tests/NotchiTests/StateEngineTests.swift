import XCTest
@testable import Notchi

final class StateEngineTests: XCTestCase {

    func test_sessionStart_then_toolStarted_then_stopped() async {
        let e = StateEngine()
        await e.apply(.sessionStarted(sessionID: "s1", cwd: "/Users/dev/code/notchi"))
        var st = await e.state(for: "s1")
        XCTAssertEqual(st, .idleWaiting)

        await e.apply(.toolStarted(sessionID: "s1", cwd: nil, tool: .bash))
        st = await e.state(for: "s1")
        XCTAssertEqual(st, .working(.bash))

        await e.apply(.stopped(sessionID: "s1"))
        st = await e.state(for: "s1")
        XCTAssertEqual(st, .celebrating)   // a turn that did work ends with a happy hop
    }

    func test_sessionEnded_evicts() async {
        let e = StateEngine()
        await e.apply(.sessionStarted(sessionID: "s1", cwd: "/x"))
        await e.apply(.sessionEnded(sessionID: "s1"))
        let st = await e.state(for: "s1")
        XCTAssertNil(st)
    }

    func test_toolStarted_increments_toolCount_and_sets_cwd() async {
        let e = StateEngine()
        await e.apply(.toolStarted(sessionID: "s1", cwd: "/Users/dev/code/demoapp", tool: .edit))
        await e.apply(.toolFinished(sessionID: "s1", error: false))
        await e.apply(.toolStarted(sessionID: "s1", cwd: nil, tool: .read))
        let s = await e.session(for: "s1")
        XCTAssertEqual(s?.toolCount, 2)
        XCTAssertEqual(s?.projectName, "demoapp")
        XCTAssertEqual(s?.state, .working(.read))
    }

    func test_notification_sets_attention() async {
        let e = StateEngine()
        await e.apply(.sessionStarted(sessionID: "s1", cwd: "/x"))
        await e.apply(.attention(sessionID: "s1", message: "needs permission"))
        let s = await e.session(for: "s1")
        XCTAssertEqual(s?.needsAttention, true)
        // A subsequent tool clears attention.
        await e.apply(.toolStarted(sessionID: "s1", cwd: nil, tool: .bash))
        let s2 = await e.session(for: "s1")
        XCTAssertEqual(s2?.needsAttention, false)
    }

    func test_gate_permission_then_approve() async {
        let e = StateEngine()
        await e.apply(.sessionStarted(sessionID: "s1", cwd: "/x"))
        let req = PermissionRequest(id: "req1", tool: .bash, toolRawName: "Bash", preview: "ls")
        await e.apply(.permissionRequested(sessionID: "s1", request: req))
        XCTAssertEqual(await e.state(for: "s1"), .waitingPermission(req))

        await e.apply(.userPermissionResponse(requestID: "req1", decision: .approve))
        XCTAssertEqual(await e.state(for: "s1"), .working(.bash))
    }

    func test_gate_permission_then_deny() async {
        let e = StateEngine()
        await e.apply(.sessionStarted(sessionID: "s1", cwd: "/x"))
        let req = PermissionRequest(id: "req2", tool: .edit, toolRawName: "Edit", preview: "/f.swift")
        await e.apply(.permissionRequested(sessionID: "s1", request: req))
        await e.apply(.userPermissionResponse(requestID: "req2", decision: .deny))
        XCTAssertEqual(await e.state(for: "s1"), .idleWaiting)
    }

    func test_multiple_sessions_sorted_by_priority() async {
        let e = StateEngine()
        await e.apply(.sessionStarted(sessionID: "idle", cwd: "/a"))      // idleWaiting
        await e.apply(.sessionStarted(sessionID: "work", cwd: "/b"))
        await e.apply(.toolStarted(sessionID: "work", cwd: nil, tool: .bash))  // working
        let sessions = await e.currentSessions()
        XCTAssertEqual(sessions.first?.id, "work")   // working sorts before idleWaiting
        XCTAssertEqual(sessions.count, 2)
    }
}
