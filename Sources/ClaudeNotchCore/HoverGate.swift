import Foundation

/// Debounces "pointer is over the island" into a stable hover state.
///
/// Hover is fed from the real pointer position against the island's *final* rectangle. The raw signal
/// can flicker (the pointer grazing an edge, the window being resized under the cursor), and reacting
/// to every flip makes the island open and close repeatedly. The gate requires the pointer to dwell
/// inside before opening and to stay outside for a grace period before closing.
public struct HoverGate: Sendable, Equatable {
    public var enterDelay: TimeInterval
    public var exitDelay: TimeInterval
    public private(set) var isHovering = false
    private var insideSince: Date?
    private var outsideSince: Date?

    public init(enterDelay: TimeInterval = 0.09, exitDelay: TimeInterval = 0.32) {
        self.enterDelay = enterDelay; self.exitDelay = exitDelay
    }

    /// Feed the latest raw sample; returns the debounced state.
    @discardableResult
    public mutating func update(inside: Bool, now: Date) -> Bool {
        if inside {
            outsideSince = nil
            if insideSince == nil { insideSince = now }
            if !isHovering, now.timeIntervalSince(insideSince!) >= enterDelay { isHovering = true }
        } else {
            insideSince = nil
            if outsideSince == nil { outsideSince = now }
            if isHovering, now.timeIntervalSince(outsideSince!) >= exitDelay { isHovering = false }
        }
        return isHovering
    }

    public mutating func reset() { isHovering = false; insideSince = nil; outsideSince = nil }
}
