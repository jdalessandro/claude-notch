import AppIntents
import Foundation

/// Where the intents deliver their result. `perform()` runs inside the host app's process (verified in the spike),
/// which registers the handler at launch. In the widget extension the handler stays nil: the buttons are only drawn there.
@MainActor
enum IntentBridge {
    enum Action: Sendable {
        case allow, allowSession, deny, open, review, nextPage, previousPage, refreshQuota, openSettings, focusSubagents
        case chooseAnswer, pickAnswer
    }
    static var handler: (@MainActor (Action, _ sessionId: String, _ requestId: String, _ option: Int) -> Void)?
}

/// Intents must be compiled into the app *and* the widget. Each carries the request it answers, so a duplicated or
/// stale tap is ignored by the model instead of answering a newer request.
struct AllowIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Allow"
    @Parameter(title: "Session") var sessionId: String
    @Parameter(title: "Request") var requestId: String
    init() {}
    init(sessionId: String, requestId: String) { self.sessionId = sessionId; self.requestId = requestId }
    @MainActor func perform() async throws -> some IntentResult {
        IntentBridge.handler?(.allow, sessionId, requestId, 0)
        return .result()
    }
}

/// "Allow for session": allows this request and adds Claude Code's suggested rule for the rest of the session.
struct AllowSessionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Allow for this session"
    @Parameter(title: "Session") var sessionId: String
    @Parameter(title: "Request") var requestId: String
    init() {}
    init(sessionId: String, requestId: String) { self.sessionId = sessionId; self.requestId = requestId }
    @MainActor func perform() async throws -> some IntentResult {
        IntentBridge.handler?(.allowSession, sessionId, requestId, 0)
        return .result()
    }
}

struct DenyIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Deny"
    @Parameter(title: "Session") var sessionId: String
    @Parameter(title: "Request") var requestId: String
    init() {}
    init(sessionId: String, requestId: String) { self.sessionId = sessionId; self.requestId = requestId }
    @MainActor func perform() async throws -> some IntentResult {
        IntentBridge.handler?(.deny, sessionId, requestId, 0)
        return .result()
    }
}

/// Brings the session's terminal / Claude app to the front (and answers a question by letting it through).
struct OpenSessionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Open"
    @Parameter(title: "Session") var sessionId: String
    @Parameter(title: "Request") var requestId: String
    init() {}
    init(sessionId: String, requestId: String = "") { self.sessionId = sessionId; self.requestId = requestId }
    @MainActor func perform() async throws -> some IntentResult {
        IntentBridge.handler?(.open, sessionId, requestId, 0)
        return .result()
    }
}

/// Asks the app to feature a request as the full card (whole command, branch, risk) before it is answered.
struct ReviewIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Review request"
    @Parameter(title: "Session") var sessionId: String
    @Parameter(title: "Request") var requestId: String
    init() {}
    init(sessionId: String, requestId: String) { self.sessionId = sessionId; self.requestId = requestId }
    @MainActor func perform() async throws -> some IntentResult {
        IntentBridge.handler?(.review, sessionId, requestId, 0)
        return .result()
    }
}

/// Pages through the island's session list (a Live Activity can't scroll). The app owns the page number.
struct PageIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Change page"
    @Parameter(title: "Forward") var forward: Bool
    init() {}
    init(forward: Bool) { self.forward = forward }
    @MainActor func perform() async throws -> some IntentResult {
        IntentBridge.handler?(forward ? .nextPage : .previousPage, "", "", 0)
        return .result()
    }
}

/// Shows (or, tapped again or with an empty session, hides) a session's subagent tree in place of the session list.
/// The app owns which session is focused.
struct FocusSubagentsIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Show subagents"
    @Parameter(title: "Session") var sessionId: String
    init() {}
    init(sessionId: String) { self.sessionId = sessionId }
    @MainActor func perform() async throws -> some IntentResult {
        IntentBridge.handler?(.focusSubagents, sessionId, "", 0)
        return .result()
    }
}

/// Opens a question's choices as their own view (or, with an empty request, goes back to the sessions).
struct ChooseAnswerIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Choose an answer"
    @Parameter(title: "Session") var sessionId: String
    @Parameter(title: "Request") var requestId: String
    init() {}
    init(sessionId: String, requestId: String) { self.sessionId = sessionId; self.requestId = requestId }
    @MainActor func perform() async throws -> some IntentResult {
        IntentBridge.handler?(.chooseAnswer, sessionId, requestId, 0)
        return .result()
    }
}

/// Answers Claude's question with choice number `option` (0-based).
struct PickAnswerIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Answer"
    @Parameter(title: "Session") var sessionId: String
    @Parameter(title: "Request") var requestId: String
    @Parameter(title: "Choice") var option: Int
    init() {}
    init(sessionId: String, requestId: String, option: Int) {
        self.sessionId = sessionId; self.requestId = requestId; self.option = option
    }
    @MainActor func perform() async throws -> some IntentResult {
        IntentBridge.handler?(.pickAnswer, sessionId, requestId, option)
        return .result()
    }
}

/// Re-reads the plan limits from Anthropic right now (the footer's refresh icon).
struct RefreshQuotaIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Refresh plan limits"
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        IntentBridge.handler?(.refreshQuota, "", "", 0)
        return .result()
    }
}

/// Opens NotchBot's settings window (the island's gear icon).
struct OpenSettingsIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Open settings"
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        IntentBridge.handler?(.openSettings, "", "", 0)
        return .result()
    }
}
