import Foundation

/// Fixed row geometry for the compact (abbreviated) island, so its size is known without measuring.
public enum CompactLayout {
    public static let rowHeight: CGFloat = 52
    public static let gap: CGFloat = 6
    public static let maxRows = 6
    public static let overflowHeight: CGFloat = 22
    public static let emptyHeight: CGFloat = 56
    public static let width: CGFloat = 320

    /// Height of the list area for `count` sessions (rows beyond `maxRows` collapse into one overflow line).
    public static func listHeight(sessionCount count: Int) -> CGFloat {
        guard count > 0 else { return emptyHeight }
        let rows = min(count, maxRows)
        return CGFloat(rows) * rowHeight + CGFloat(rows - 1) * gap + (count > maxRows ? overflowHeight : 0)
    }
}
