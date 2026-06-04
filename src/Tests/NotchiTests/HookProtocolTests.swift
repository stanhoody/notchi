import XCTest
@testable import Notchi

final class HookProtocolTests: XCTestCase {

    func test_decode_session_start() {
        let line = #"{"hook_event_name":"SessionStart","session_id":"sess1","cwd":"/Users/dev/code/foo","transcript_path":"/x.jsonl","source":"startup"}"#
        guard case .sessionStart(let p) = HookLineDecoder.decode(line) else {
            return XCTFail("expected sessionStart")
        }
        XCTAssertEqual(p.sessionID, "sess1")
        XCTAssertEqual(p.cwd, "/Users/dev/code/foo")
        XCTAssertEqual(p.source, "startup")
    }

    func test_decode_stop() {
        let line = #"{"hook_event_name":"Stop","session_id":"s","cwd":"/x","stop_hook_active":false}"#
        guard case .stop(let p) = HookLineDecoder.decode(line) else {
            return XCTFail("expected stop")
        }
        XCTAssertEqual(p.sessionID, "s")
    }

    func test_decode_session_end() {
        let line = #"{"hook_event_name":"SessionEnd","session_id":"s","reason":"clear"}"#
        guard case .sessionEnd(let p) = HookLineDecoder.decode(line) else {
            return XCTFail("expected sessionEnd")
        }
        XCTAssertEqual(p.reason, "clear")
    }

    func test_decode_pre_tool_use_bash() {
        let line = #"{"hook_event_name":"PreToolUse","session_id":"s","cwd":"/x","tool_name":"Bash","tool_input":{"command":"rm -rf node_modules","description":"clean deps"}}"#
        guard case .preToolUse(let p) = HookLineDecoder.decode(line) else {
            return XCTFail("expected preToolUse")
        }
        XCTAssertEqual(p.toolName, "Bash")
        XCTAssertEqual(p.preview, "rm -rf node_modules")
        XCTAssertEqual(p.descriptionText, "clean deps")
    }

    func test_decode_pre_tool_use_edit_preview_is_file_path() {
        let line = #"{"hook_event_name":"PreToolUse","session_id":"s","tool_name":"Edit","tool_input":{"file_path":"/tmp/x.swift","old_string":"foo","new_string":"bar"}}"#
        guard case .preToolUse(let p) = HookLineDecoder.decode(line) else {
            return XCTFail("expected preToolUse")
        }
        XCTAssertEqual(p.preview, "/tmp/x.swift")
    }

    func test_decode_notification() {
        let line = #"{"hook_event_name":"Notification","session_id":"s","message":"Claude needs your permission to use Bash"}"#
        guard case .notification(let p) = HookLineDecoder.decode(line) else {
            return XCTFail("expected notification")
        }
        XCTAssertEqual(p.message, "Claude needs your permission to use Bash")
    }

    func test_transcript_line_is_ignored() {
        // A real JSONL transcript line keys on `type`, not `hook_event_name`.
        let line = #"{"type":"assistant","uuid":"abc","sessionId":"s","timestamp":"2026-06-03T00:00:00Z"}"#
        XCTAssertNil(HookLineDecoder.decode(line))
    }

    func test_unknown_event_maps_to_unknown() {
        let line = #"{"hook_event_name":"SomeFutureEvent","session_id":"s"}"#
        guard case .unknown(let raw, _) = HookLineDecoder.decode(line) else {
            return XCTFail("expected unknown")
        }
        XCTAssertEqual(raw, "SomeFutureEvent")
    }

    func test_malformed_json_returns_nil() {
        XCTAssertNil(HookLineDecoder.decode("not json at all"))
        XCTAssertNil(HookLineDecoder.decode(""))
    }

    func test_response_encoding_approve() throws {
        let resp = PreToolUseResponse(decision: .approve)
        let json = try XCTUnwrap(String(data: try JSONEncoder().encode(resp), encoding: .utf8))
        XCTAssertTrue(json.contains("\"decision\":\"approve\""))
    }

    func test_response_encoding_deny_with_reason() throws {
        let resp = PreToolUseResponse(decision: .deny, reason: "no rm -rf")
        let json = try XCTUnwrap(String(data: try JSONEncoder().encode(resp), encoding: .utf8))
        XCTAssertTrue(json.contains("\"decision\":\"deny\""))
        XCTAssertTrue(json.contains("\"reason\":\"no rm -rf\""))
    }
}
