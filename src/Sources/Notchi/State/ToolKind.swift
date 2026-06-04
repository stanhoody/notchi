import Foundation

/// Maps a Claude Code tool name to the sprite family Notchi shows.
///
/// Per design.md, four sprite families:
/// - `.edit` (pencil pose) for Edit/MultiEdit/Write/NotebookEdit
/// - `.bash` (mini-terminal pose) for Bash
/// - `.read` (book pose) for Read/Glob/Grep
/// - `.other(name)` (gear pose) for everything else (WebFetch, Task, MCP, …)
public enum ToolKind: Equatable, Hashable, Sendable {
    case edit
    case bash
    case read
    case web
    case plan
    case other(String)

    /// Public API for callers that don't care which "other" tool fired.
    public var spriteFamily: SpriteFamily {
        switch self {
        case .edit: return .edit
        case .bash: return .bash
        case .read: return .read
        case .web:  return .web
        case .plan: return .plan
        case .other: return .other
        }
    }

    /// Mapping from raw Claude tool name → ToolKind.
    /// Read/Glob/Grep collapse to `.read` intentionally — sprite would change too fast otherwise.
    public static func from(_ rawToolName: String) -> ToolKind {
        switch rawToolName {
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            return .edit
        case "Bash":
            return .bash
        case "Read", "Glob", "Grep", "LS", "NotebookRead":
            return .read
        case "WebFetch", "WebSearch":
            return .web
        case "TodoWrite", "ExitPlanMode", "exit_plan_mode":
            return .plan
        default:
            return .other(rawToolName)
        }
    }
}

public enum SpriteFamily: String, Sendable {
    case edit, bash, read, web, plan, other
}
