import XCTest
@testable import Notchi

final class HookInstallerTests: XCTestCase {

    private func makeTempConfigDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchi-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func readSettings(_ dir: URL) -> [String: Any] {
        let url = dir.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    func test_install_writes_nested_schema_and_scripts() throws {
        let dir = makeTempConfigDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try HookInstaller.install(configDir: dir)

        // Scripts on disk + executable.
        let scripts = dir.appendingPathComponent("hooks/notchi")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: scripts.appendingPathComponent("notchi-event.sh").path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: scripts.appendingPathComponent("notchi-pretooluse.sh").path))

        // Nested schema: hooks.PreToolUse[0].hooks[0].command points at our script.
        let settings = readSettings(dir)
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        let pre = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        let inner = try XCTUnwrap(pre.first?["hooks"] as? [[String: Any]])
        let cmd = try XCTUnwrap(inner.first?["command"] as? String)
        XCTAssertTrue(cmd.hasSuffix("notchi-pretooluse.sh"))
        XCTAssertEqual(inner.first?["type"] as? String, "command")

        XCTAssertTrue(HookInstaller.status(configDir: dir).settingsRegistered)
    }

    func test_install_preserves_existing_hooks() throws {
        let dir = makeTempConfigDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Seed an existing SessionStart hook like Stan's claude-sync-pull.
        let existing: [String: Any] = [
            "hooks": [
                "SessionStart": [
                    ["hooks": [["type": "command", "command": "$HOME/bin/claude-sync-pull.sh"]]]
                ]
            ],
            "model": "opus"
        ]
        let data = try JSONSerialization.data(withJSONObject: existing)
        try data.write(to: dir.appendingPathComponent("settings.json"))

        try HookInstaller.install(configDir: dir)

        let settings = readSettings(dir)
        XCTAssertEqual(settings["model"] as? String, "opus")   // untouched
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        let sessionStart = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        // Both the sync hook AND Notchi's entry survive.
        let commands = sessionStart.compactMap { ($0["hooks"] as? [[String: Any]])?.first?["command"] as? String }
        XCTAssertTrue(commands.contains { $0.contains("claude-sync-pull.sh") })
        XCTAssertTrue(commands.contains { $0.contains("notchi-event.sh") })
    }

    func test_install_is_idempotent() throws {
        let dir = makeTempConfigDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try HookInstaller.install(configDir: dir)
        try HookInstaller.install(configDir: dir)

        let settings = readSettings(dir)
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        let pre = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(pre.count, 1, "re-install must not duplicate Notchi entries")
    }

    func test_uninstall_removes_only_notchi() throws {
        let dir = makeTempConfigDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let existing: [String: Any] = [
            "hooks": ["SessionStart": [
                ["hooks": [["type": "command", "command": "$HOME/bin/claude-sync-pull.sh"]]]
            ]]
        ]
        try JSONSerialization.data(withJSONObject: existing)
            .write(to: dir.appendingPathComponent("settings.json"))

        try HookInstaller.install(configDir: dir)
        try HookInstaller.uninstall(configDir: dir)

        let settings = readSettings(dir)
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        let sessionStart = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        let commands = sessionStart.compactMap { ($0["hooks"] as? [[String: Any]])?.first?["command"] as? String }
        XCTAssertTrue(commands.contains { $0.contains("claude-sync-pull.sh") })
        XCTAssertFalse(commands.contains { $0.contains("notchi") })
        XCTAssertNil(hooks["PreToolUse"], "PreToolUse had only Notchi → key removed")
        XCTAssertFalse(HookInstaller.status(configDir: dir).settingsRegistered)
    }
}
