import AppIntents
import Foundation
import os

func mark(_ s: String) {
    let line = "\(Date()) pid=\(getpid()) \(Bundle.main.bundleIdentifier ?? "?") \(s)\n"
    let url = URL(fileURLWithPath: "/tmp/notchlive-intent.log")
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
    else { try? line.write(to: url, atomically: false, encoding: .utf8) }
}

/// Allow / Deny buttons inside the activity. They must be LiveActivityIntents compiled into the app *and* the widget.
struct AllowIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Allow"
    func perform() async throws -> some IntentResult {
        Logger(subsystem: "dev.claudenotch.live", category: "intent").notice("INTENT allow fired")
        mark("allow")
        return .result()
    }
}

struct DenyIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Deny"
    func perform() async throws -> some IntentResult {
        Logger(subsystem: "dev.claudenotch.live", category: "intent").notice("INTENT deny fired")
        mark("deny")
        return .result()
    }
}
