import Foundation

/// The header band shares its row with the hardware cutout, which is physically opaque and sits in the middle of
/// the island. Content must never run under it, so each side of the header gets a computed safe width and is
/// responsible for fitting inside it (longest wording that fits, then shorter ones).
public enum SafeZone {
    /// Padding between the island's outer edge and the header content.
    public static let outerPadding = 20.0
    /// Extra clearance kept on each side of the cutout so text never touches it.
    public static let cutoutMargin = 10.0
    /// Never report less than this, so a very narrow island degrades gracefully instead of collapsing.
    public static let minimumSide = 36.0

    /// Width available to each of the two header groups (left and right of the cutout).
    public static func sideWidth(
        islandWidth: Double, cutoutWidth: Double, outerPadding: Double = outerPadding, margin: Double = cutoutMargin
    ) -> Double {
        let free = islandWidth - cutoutWidth - 2 * margin - 2 * outerPadding
        return max(minimumSide, free / 2)
    }

    /// Whether content of `contentWidth` on one side stays clear of the cutout.
    public static func fits(contentWidth: Double, islandWidth: Double, cutoutWidth: Double) -> Bool {
        contentWidth <= sideWidth(islandWidth: islandWidth, cutoutWidth: cutoutWidth)
    }
}
