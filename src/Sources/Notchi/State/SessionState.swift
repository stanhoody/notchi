import Foundation

/// Per-session state per the state machine in architecture.md §State machine.
public enum SessionState: Equatable, Sendable {
    /// No Claude Code session active for this slot. Not actually stored in StateEngine —
    /// the absence of a key in `sessions` map is the idle-no-session signal.
    case idle

    /// Session is active but Claude finished a turn. Ball in Stan's court.
    case idleWaiting

    /// Claude is mid-tool-use. `ToolKind` selects the sprite family.
    case working(ToolKind)

    /// Between tools — a tool just finished and Claude is composing the next step.
    case thinking

    /// Just wrapped up a turn — a brief happy hop before settling. Engine auto-reverts to idle.
    case celebrating

    /// A tool just failed — a brief confused beat. Engine auto-reverts to thinking.
    case confused

    /// PreToolUse hook fired and is blocked waiting for Approve/Deny via the popup.
    case waitingPermission(PermissionRequest)
}

/// A pending permission decision being held by HookBridge.
/// `id` correlates app → hook responses.
public struct PermissionRequest: Equatable, Sendable {
    public let id: String
    public let tool: ToolKind
    public let toolRawName: String      // e.g. "Bash" — for popup tool-name header
    public let preview: String          // first line of command / file / etc.
    public let description: String?     // optional second-line context
    public let timestamp: Date

    public init(id: String,
                tool: ToolKind,
                toolRawName: String,
                preview: String,
                description: String? = nil,
                timestamp: Date = Date()) {
        self.id = id
        self.tool = tool
        self.toolRawName = toolRawName
        self.preview = preview
        self.description = description
        self.timestamp = timestamp
    }
}

/// Stable session identifier as reported by Claude Code in hook events.
public typealias SessionID = String

/// Per-session bookkeeping kept inside StateEngine alongside the state itself.
public struct SessionData: Equatable, Sendable {
    public var state: SessionState
    public let id: SessionID
    public var cwd: String
    public var model: String
    public let startedAt: Date
    public var lastActivity: Date
    /// Set by a Claude `Notification` hook (e.g. "needs your permission", "waiting for input").
    /// Drives the wave animation in observational mode. Cleared on the next tool/stop event.
    public var needsAttention: Bool
    /// The latest Notification message (shown in the observational popup).
    public var attentionMessage: String?
    /// Running count of tool calls observed this session (activity stat for the click popup).
    public var toolCount: Int
    /// When the current continuous working stretch began (nil when not working). Drives the
    /// "long task → tired/coffee" look after 30s.
    public var workingSince: Date?
    /// Active Task-tool sub-agents — rendered as mini companions linked to this character.
    public var subAgentCount: Int = 0
    /// A sarcastic one-liner shown in the bubble, with its expiry time.
    public var quip: String?
    public var quipUntil: Date?

    public init(id: SessionID,
                cwd: String,
                model: String,
                startedAt: Date,
                state: SessionState = .idleWaiting,
                needsAttention: Bool = false,
                attentionMessage: String? = nil,
                toolCount: Int = 0) {
        self.id = id
        self.cwd = cwd
        self.model = model
        self.startedAt = startedAt
        self.lastActivity = startedAt
        self.state = state
        self.needsAttention = needsAttention
        self.attentionMessage = attentionMessage
        self.toolCount = toolCount
        self.workingSince = nil
    }

    /// Short project name derived from the last path component of `cwd`.
    public var projectName: String {
        let last = (cwd as NSString).lastPathComponent
        return last.isEmpty ? "—" : last
    }
}

extension SessionState {
    /// Sort priority used by multi-session layout (waitingPermission first, then working, then idleWaiting).
    /// Per sk-ruban-cross-reference.md correction #2: active work in front.
    public var sortPriority: Int {
        switch self {
        case .waitingPermission: return 6
        case .confused: return 5
        case .working: return 4
        case .thinking: return 3
        case .celebrating: return 2
        case .idleWaiting: return 1
        case .idle: return 0
        }
    }
}
