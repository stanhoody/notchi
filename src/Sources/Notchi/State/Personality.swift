import Foundation

/// Notchi's voice — short deadpan/sarcastic quips shown in the speech bubble for a beat.
/// This is the "personality as the wedge" angle from the original brief: the creature reacts
/// to spicy moments instead of being mute-cute.
enum Quips {
    static let dangerLines = ["seriously?", "bold.", "no undo, fyi", "you sure?", "yikes.", "living on the edge", "rm -rf, huh."]
    static let errorLines  = ["welp.", "that broke.", "oops.", "rip.", "nice one."]

    static func danger() -> String { dangerLines.randomElement() ?? "seriously?" }
    static func error() -> String { errorLines.randomElement() ?? "welp." }

    /// Best-effort: is this Bash command worth a raised eyebrow?
    static func isSpicy(_ command: String) -> Bool {
        let c = command.lowercased()
        let needles = [
            "rm -rf", "rm -fr", "rm -r ", "sudo ", "chmod 777", "chmod -r",
            "git reset --hard", "--force", "push -f", "force-push",
            "dd if=", "mkfs", ":(){", "kill -9", "killall", "> /dev/sd",
            "| sh", "|sh", "curl -fssl", "npm publish", "drop table", "drop database",
        ]
        return needles.contains { c.contains($0) }
    }
}
