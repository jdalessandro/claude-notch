import AppIntents
import Foundation
import os

/// Allow / Deny buttons inside the activity. They must be LiveActivityIntents compiled into the app *and* the widget.
struct AllowIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Allow"
    func perform() async throws -> some IntentResult {
        Logger(subsystem: "dev.claudenotch.live", category: "intent").notice("INTENT allow fired")
        return .result()
    }
}

struct DenyIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Deny"
    func perform() async throws -> some IntentResult {
        Logger(subsystem: "dev.claudenotch.live", category: "intent").notice("INTENT deny fired")
        return .result()
    }
}
