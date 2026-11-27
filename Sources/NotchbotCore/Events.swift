import Foundation

/// Minimal tolerant JSON value. Hook payloads evolve between Claude Code releases,
/// so we never fail decoding on an unknown field or shape.
public enum JSONValue: Codable, Sendable, Equatable {
    case null, bool(Bool), number(Double), string(String)
    case array([JSONValue]), object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Double.self) {
            self = .number(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([JSONValue].self) {
            self = .array(v)
        } else if let v = try? c.decode([String: JSONValue].self) {
            self = .object(v)
        } else {
            self = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }

    /// Copy with every string (at any depth) capped to `maxChars`.
    public func truncatingStrings(to maxChars: Int) -> JSONValue {
        switch self {
        case .string(let s): return .string(s.count > maxChars ? String(s.prefix(maxChars)) + "…" : s)
        case .array(let a): return .array(a.map { $0.truncatingStrings(to: maxChars) })
        case .object(let o): return .object(o.mapValues { $0.truncatingStrings(to: maxChars) })
        default: return self
        }
    }
}

/// What Claude Code writes to a hook command's stdin (fields we use; all optional on purpose).
///
/// Decoding is deliberately lenient *per field*: a field with an unexpected JSON type (for example the
/// status line's `model`, which is an object `{id, display_name}` while hooks send a string) becomes nil
/// instead of failing the whole payload. A failed decode used to make the forwarder drop the event
/// silently, which broke quota gauges entirely.
public struct HookPayload: Codable, Sendable, Equatable {
    public var sessionId: String?
    public var transcriptPath: String?
    public var cwd: String?
    public var hookEventName: String?
    public var permissionMode: String?
    // Notification
    public var message: String?
    public var title: String?
    public var notificationType: String?
    // Tools
    public var toolName: String?
    public var toolInput: JSONValue?
    public var toolUseId: String?
    // Prompt / session
    public var prompt: String?
    public var source: String?
    public var reason: String?
    public var model: String?
    public var lastAssistantMessage: String?
    /// Present on events that fire inside a subagent.
    public var agentId: String?
    public var agentType: String?
    /// PermissionRequest only: Claude Code's suggested permission updates (e.g. an `addRules` entry for this command).
    public var permissionSuggestions: JSONValue?
    /// Status-line only: `rate_limits` (subscribers) and `context_window`.
    public var rateLimits: JSONValue?
    public var contextWindow: JSONValue?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case hookEventName = "hook_event_name"
        case permissionMode = "permission_mode"
        case message, title
        case notificationType = "notification_type"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case toolUseId = "tool_use_id"
        case prompt, source, reason, model
        case lastAssistantMessage = "last_assistant_message"
        case agentId = "agent_id"
        case agentType = "agent_type"
        case permissionSuggestions = "permission_suggestions"
        case rateLimits = "rate_limits"
        case contextWindow = "context_window"
    }

    public init(
        sessionId: String? = nil, transcriptPath: String? = nil, cwd: String? = nil,
        hookEventName: String? = nil, message: String? = nil, notificationType: String? = nil,
        toolName: String? = nil, toolInput: JSONValue? = nil, prompt: String? = nil,
        reason: String? = nil
    ) {
        self.sessionId = sessionId
        self.transcriptPath = transcriptPath
        self.cwd = cwd
        self.hookEventName = hookEventName
        self.message = message
        self.notificationType = notificationType
        self.toolName = toolName
        self.toolInput = toolInput
        self.prompt = prompt
        self.reason = reason
    }

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: DynamicKey.self)
        func load<T: Decodable>(_ kp: WritableKeyPath<HookPayload, T?>, _ key: CodingKeys) {
            self[keyPath: kp] = (try? c.decodeIfPresent(T.self, forKey: DynamicKey(key.rawValue))) ?? nil
        }
        load(\.sessionId, .sessionId); load(\.transcriptPath, .transcriptPath); load(\.cwd, .cwd)
        load(\.hookEventName, .hookEventName); load(\.permissionMode, .permissionMode)
        load(\.message, .message); load(\.title, .title); load(\.notificationType, .notificationType)
        load(\.toolName, .toolName); load(\.toolInput, .toolInput); load(\.toolUseId, .toolUseId)
        load(\.prompt, .prompt); load(\.source, .source); load(\.reason, .reason)
        load(\.lastAssistantMessage, .lastAssistantMessage)
        load(\.agentId, .agentId); load(\.agentType, .agentType); load(\.permissionSuggestions, .permissionSuggestions)
        load(\.rateLimits, .rateLimits); load(\.contextWindow, .contextWindow)
        // `model` is a string in hooks but an object ({id, display_name}) in the status line.
        if let v = try? c.decodeIfPresent(JSONValue.self, forKey: DynamicKey(CodingKeys.model.rawValue)) {
            model = v.stringValue ?? v["id"]?.stringValue ?? v["display_name"]?.stringValue
        }
    }

    /// Caps every free-text field so one giant prompt or file write can't make the event huge.
    /// Applied by the forwarder before sending; the island only ever shows a few lines anyway.
    public func truncated(maxChars: Int = 4_000) -> HookPayload {
        var p = self
        func cut(_ s: String?) -> String? { s.map { $0.count > maxChars ? String($0.prefix(maxChars)) + "…" : $0 } }
        p.prompt = cut(prompt)
        p.message = cut(message)
        p.lastAssistantMessage = cut(lastAssistantMessage)
        p.reason = cut(reason)
        p.toolInput = toolInput?.truncatingStrings(to: maxChars)
        // Never truncate a suggested rule (a clipped command would be a different rule): keep it whole or drop it.
        if let s = permissionSuggestions, ((try? JSONEncoder().encode(s).count) ?? Int.max) > 8_000 { p.permissionSuggestions = nil }
        return p
    }
}

/// Wire message from `notchbot-hook` to the app (one JSON object per line).
public struct HookEnvelope: Codable, Sendable, Equatable {
    public var payload: HookPayload
    public var receivedAt: Date
    /// PID of the process that invoked the hook (usually the `claude` process or its shell).
    public var pid: Int32?
    public var termProgram: String?
    public var tty: String?
    /// True when the hook is blocked waiting for the app to answer (permission round-trip).
    public var expectsReply: Bool

    public init(
        payload: HookPayload, receivedAt: Date = Date(), pid: Int32? = nil,
        termProgram: String? = nil, tty: String? = nil, expectsReply: Bool = false
    ) {
        self.payload = payload; self.receivedAt = receivedAt; self.pid = pid
        self.termProgram = termProgram; self.tty = tty; self.expectsReply = expectsReply
    }

    public func encodedLine() throws -> Data {
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970
        return try e.encode(self) + Data("\n".utf8)
    }
    public static func decode(_ data: Data) throws -> HookEnvelope {
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970
        return try d.decode(HookEnvelope.self, from: data)
    }
}

/// The user's answer to a permission request shown in the notch.
public enum PermissionDecision: String, Codable, Sendable {
    case allow, deny
    /// Fall through to Claude Code's normal terminal prompt.
    case ask
}

public struct HookReply: Codable, Sendable, Equatable {
    public var decision: PermissionDecision
    public var reason: String?
    /// Permission updates to apply with an allow (`hookSpecificOutput.decision.updatedPermissions`).
    public var updatedPermissions: [JSONValue]?
    public init(decision: PermissionDecision, reason: String? = nil, updatedPermissions: [JSONValue]? = nil) {
        self.decision = decision; self.reason = reason; self.updatedPermissions = updatedPermissions
    }
}
