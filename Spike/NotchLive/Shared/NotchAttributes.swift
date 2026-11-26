import ActivityKit
import Foundation

/// Static data for the Live Activity plus the part that changes while it runs.
struct NotchAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var agents: Int
        var needsYou: Int
        var headline: String
        var detail: String
        var approvalPending: Bool
    }
    var title: String
}
