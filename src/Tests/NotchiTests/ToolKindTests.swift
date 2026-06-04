import XCTest
@testable import Notchi

final class ToolKindTests: XCTestCase {

    func test_edit_family() {
        XCTAssertEqual(ToolKind.from("Edit"), .edit)
        XCTAssertEqual(ToolKind.from("MultiEdit"), .edit)
        XCTAssertEqual(ToolKind.from("Write"), .edit)
        XCTAssertEqual(ToolKind.from("NotebookEdit"), .edit)
    }

    func test_bash() {
        XCTAssertEqual(ToolKind.from("Bash"), .bash)
    }

    func test_read_family_collapses_glob_and_grep() {
        XCTAssertEqual(ToolKind.from("Read"), .read)
        XCTAssertEqual(ToolKind.from("Glob"), .read)
        XCTAssertEqual(ToolKind.from("Grep"), .read)
    }

    func test_other_preserves_raw_name() {
        XCTAssertEqual(ToolKind.from("WebFetch"), .other("WebFetch"))
        XCTAssertEqual(ToolKind.from("Task"), .other("Task"))
        XCTAssertEqual(ToolKind.from("mcp__sentry__find_issues"), .other("mcp__sentry__find_issues"))
    }

    func test_sprite_family_collapses_others() {
        XCTAssertEqual(ToolKind.from("WebFetch").spriteFamily, .other)
        XCTAssertEqual(ToolKind.from("Task").spriteFamily, .other)
        XCTAssertEqual(ToolKind.from("Edit").spriteFamily, .edit)
    }
}
