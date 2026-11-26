import AppIntents
import Foundation

/// Where the intents deliver their result. `perform()` runs inside the host app's process (verified in the spike),
/// which registers the handler at launch. In the widget extension the handler stays nil: the buttons are only drawn there.
@MainActor
enum IntentBridge {
    enum Action: Sendable { case allow, deny, open, nextPage, previousPage, refreshQuota }
    static var handler: (@MainActor (Action, _ sessionId: String, _ requestId: String) -> Void)?
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
        IntentBridge.handler?(.allow, sessionId, requestId)
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
        IntentBridge.handler?(.deny, sessionId, requestId)
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
        IntentBridge.handler?(.open, sessionId, requestId)
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
        IntentBridge.handler?(forward ? .nextPage : .previousPage, "", "")
        return .result()
    }
}

/// Re-reads the plan limits from Anthropic right now (the footer's refresh icon).
struct RefreshQuotaIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Refresh plan limits"
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        IntentBridge.handler?(.refreshQuota, "", "")
        return .result()
    }
}
