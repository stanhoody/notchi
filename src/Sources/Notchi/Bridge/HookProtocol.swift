import Foundation

/// Wire types for the REAL Claude Code hook JSON (forwarded verbatim by the hook scripts
/// over the Unix socket), plus the small response line the bridge writes back for PreToolUse.
///
/// Claude Code passes each hook event as a single JSON object on the hook's stdin. Common
/// fields across all events: `session_id`, `cwd`, `hook_event_name`, `transcript_path`.
/// Event-specific fields are documented per-payload below.
///
/// There is NO unique request id in the hook payload — PreToolUse correlation is by socket
/// connection. `HookBridge` mints a requestID server-side and holds the FD.

// MARK: - Inbound (hook → app), decoded by `hook_event_name`

public enum HookMessage: Sendable {
    case sessionStart(SessionStartPayload)
    case sessionEnd(SessionEndPayload)
    case stop(StopPayload)
    case subagentStop(StopPayload)
    case preToolUse(PreToolUsePayload)
    case postToolUse(PostToolUsePayload)
    case notification(NotificationPayload)
    case unknown(rawType: String, rawJSON: String)

    /// session_id of the originating session, when present.
    public var sessionID: String? {
        switch self {
        case .sessionStart(let p):  return p.sessionID
        case .sessionEnd(let p):    return p.sessionID
        case .stop(let p):          return p.sessionID
        case .subagentStop(let p):  return p.sessionID
        case .preToolUse(let p):    return p.sessionID
        case .postToolUse(let p):   return p.sessionID
        case .notification(let p):  return p.sessionID
        case .unknown:              return nil
        }
    }
}

/// Fields common to every hook payload.
private enum CommonKeys: String, CodingKey {
    case sessionID = "session_id"
    case cwd
    case transcriptPath = "transcript_path"
    case hookEventName = "hook_event_name"
}

public struct SessionStartPayload: Codable, Sendable, Equatable {
    public let sessionID: String
    public let cwd: String
    public let transcriptPath: String?
    public let source: String?          // "startup" | "clear" | "compact" | "resume"

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cwd
        case transcriptPath = "transcript_path"
        case source
    }
}

public struct SessionEndPayload: Codable, Sendable, Equatable {
    public let sessionID: String
    public let cwd: String?
    public let reason: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cwd
        case reason
    }
}

public struct StopPayload: Codable, Sendable, Equatable {
    public let sessionID: String
    public let cwd: String?
    public let stopHookActive: Bool?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cwd
        case stopHookActive = "stop_hook_active"
    }
}

public struct NotificationPayload: Codable, Sendable, Equatable {
    public let sessionID: String
    public let cwd: String?
    public let message: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cwd
        case message
    }
}

public struct PreToolUsePayload: Codable, Sendable, Equatable {
    public let sessionID: String
    public let cwd: String?
    public let transcriptPath: String?
    public let toolName: String
    public let toolInput: [String: AnyCodable]

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cwd
        case transcriptPath = "transcript_path"
        case toolName = "tool_name"
        case toolInput = "tool_input"
    }

    /// Best-effort preview of the tool's arguments for the popup body.
    public var preview: String {
        switch toolName {
        case "Bash":
            return string("command") ?? ""
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            return string("file_path") ?? ""
        case "Read", "Glob", "Grep":
            return string("file_path") ?? string("pattern") ?? string("path") ?? ""
        case "WebFetch", "WebSearch":
            return string("url") ?? string("query") ?? ""
        default:
            return toolInput.values.compactMap { $0.value as? String }.first ?? ""
        }
    }

    public var descriptionText: String? { string("description") }

    /// Bash command worth a sarcastic eyebrow (rm -rf, sudo, --force, …).
    public var isSpicy: Bool {
        guard toolName == "Bash", let cmd = string("command") else { return false }
        return Quips.isSpicy(cmd)
    }

    private func string(_ key: String) -> String? { toolInput[key]?.value as? String }
}

public struct PostToolUsePayload: Codable, Sendable, Equatable {
    public let sessionID: String
    public let cwd: String?
    public let toolName: String
    public let toolResponse: AnyCodable?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cwd
        case toolName = "tool_name"
        case toolResponse = "tool_response"
    }

    /// Best-effort: did this tool fail? Looks for common error signals in the response.
    public var isError: Bool {
        guard let v = toolResponse?.value else { return false }
        if let dict = v as? [String: Sendable] {
            if let b = dict["is_error"] as? Bool, b { return true }
            if dict["error"] != nil { return true }
            if let interrupted = dict["interrupted"] as? Bool, interrupted { return true }
        }
        if let s = v as? String {
            return s.lowercased().hasPrefix("error") || s.contains("Error:")
        }
        return false
    }
}

// MARK: - Outbound (bridge → hook script), simple internal line

/// The bridge writes this single line back to a blocked PreToolUse connection.
/// The hook script translates it into Claude Code's real `permissionDecision` JSON.
public struct PreToolUseResponse: Codable, Sendable, Equatable {
    public let decision: PermissionDecision
    public let reason: String?

    public init(decision: PermissionDecision, reason: String? = nil) {
        self.decision = decision
        self.reason = reason
    }
}

// MARK: - Lenient decoder

/// Decodes one newline-delimited JSON line. Keys on `hook_event_name`.
/// Transcript JSONL lines (which key on `type` instead) return nil and are ignored.
/// Unknown hook events map to `.unknown` rather than throwing.
public enum HookLineDecoder {
    public static func decode(_ line: String) -> HookMessage? {
        guard let data = line.data(using: .utf8) else { return nil }
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let event = json["hook_event_name"] as? String
        else { return nil }

        let dec = JSONDecoder()
        do {
            switch event {
            case "SessionStart": return .sessionStart(try dec.decode(SessionStartPayload.self, from: data))
            case "SessionEnd":   return .sessionEnd(try dec.decode(SessionEndPayload.self, from: data))
            case "Stop":         return .stop(try dec.decode(StopPayload.self, from: data))
            case "SubagentStop": return .subagentStop(try dec.decode(StopPayload.self, from: data))
            case "PreToolUse":   return .preToolUse(try dec.decode(PreToolUsePayload.self, from: data))
            case "PostToolUse":  return .postToolUse(try dec.decode(PostToolUsePayload.self, from: data))
            case "Notification": return .notification(try dec.decode(NotificationPayload.self, from: data))
            default:             return .unknown(rawType: event, rawJSON: line)
            }
        } catch {
            return .unknown(rawType: event, rawJSON: line)
        }
    }
}

// MARK: - AnyCodable (minimal, for heterogeneous tool_input dicts)

public struct AnyCodable: Codable, Sendable, Equatable {
    public let value: Sendable

    public init(_ value: Sendable) { self.value = value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self.value = NSNull()
        } else if let b = try? c.decode(Bool.self) {
            self.value = b
        } else if let i = try? c.decode(Int.self) {
            self.value = i
        } else if let d = try? c.decode(Double.self) {
            self.value = d
        } else if let s = try? c.decode(String.self) {
            self.value = s
        } else if let arr = try? c.decode([AnyCodable].self) {
            self.value = arr.map { $0.value } as [Sendable]
        } else if let dict = try? c.decode([String: AnyCodable].self) {
            self.value = dict.mapValues { $0.value } as [String: Sendable]
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "AnyCodable: unsupported JSON type")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case is NSNull:                       try c.encodeNil()
        case let b as Bool:                   try c.encode(b)
        case let i as Int:                    try c.encode(i)
        case let d as Double:                 try c.encode(d)
        case let s as String:                 try c.encode(s)
        case let arr as [Sendable]:           try c.encode(arr.map { AnyCodable($0) })
        case let dict as [String: Sendable]:  try c.encode(dict.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(value, .init(codingPath: encoder.codingPath,
                debugDescription: "AnyCodable: cannot encode \(type(of: value))"))
        }
    }

    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        switch (lhs.value, rhs.value) {
        case (is NSNull, is NSNull):              return true
        case let (a as Bool, b as Bool):          return a == b
        case let (a as Int, b as Int):            return a == b
        case let (a as Double, b as Double):      return a == b
        case let (a as String, b as String):      return a == b
        default:                                  return false
        }
    }
}
