import ActivityKit
import Foundation
import NotchbotCore

/// Static data for the Live Activity plus the part that changes while it runs (`NotchActivityState`, built and
/// size-checked in `NotchbotCore`).
struct NotchAttributes: ActivityAttributes {
    typealias ContentState = NotchActivityState
    var title: String
}
