import Foundation

/// Semantic events into the StateEngine actor. The HookBridge translates raw Claude
/// `HookMessage`s into these (it owns the socket FD, the gate flag, and mints requestIDs).
/// The JSONL watcher (Phase 4) will translate transcript lines into the same vocabulary.
public enum NotchiEvent: Sendable {
    case sessionStarted(sessionID: String, cwd: String)
    case sessionEnded(sessionID: String)
    case stopped(sessionID: String)                                   // Claude finished a turn → idleWaiting
    case toolStarted(sessionID: String, cwd: String?, tool: ToolKind) // observational: working(tool)
    case toolFinished(sessionID: String, error: Bool)                 // PostToolUse — error → confused
    case subAgentStarted(sessionID: String)                           // Task tool spawned a sub-agent
    case subAgentStopped(sessionID: String)                           // SubagentStop fired
    case quip(sessionID: String, text: String)                        // sarcastic one-liner in the bubble
    case permissionRequested(sessionID: String, request: PermissionRequest) // gate mode: waitingPermission
    case attention(sessionID: String, message: String?)              // Notification → needsAttention
    case userPermissionResponse(requestID: String, decision: PermissionDecision)
    case permissionTimedOut(requestID: String)                        // hook gave up (nc -w) → revert
    case sessionEvictionCheck
    case appWillSleep
    case appDidWake
}

public enum PermissionDecision: String, Sendable, Codable {
    case approve
    case deny
}
