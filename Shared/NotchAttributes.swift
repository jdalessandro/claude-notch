import ActivityKit
import ClaudeNotchCore
import Foundation

/// Static data for the Live Activity plus the part that changes while it runs (`NotchActivityState`, built and
/// size-checked in `ClaudeNotchCore`).
struct NotchAttributes: ActivityAttributes {
    typealias ContentState = NotchActivityState
    var title: String
}
