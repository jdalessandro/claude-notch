import AppKit

/// The macOS "Automatically hide and show the menu bar" option. macOS hides the menu bar, and the island with it, in
/// fullscreen unless this is "Never". The app only reads the option and opens the pane: writing it does not take effect
/// without the user changing it in System Settings.
enum MenuBarSetting {
    private static let promptedKey = "menuBarPromptShown"
    /// `AutoHideMenuBarOption` value for "Never" (Always = 0).
    private static let never = 3

    static var isNever: Bool {
        let v = CFPreferencesCopyAppValue("AutoHideMenuBarOption" as CFString, "com.apple.controlcenter" as CFString)
        return (v as? Int) == never
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Asks once, on first launch, when the option is not "Never".
    @MainActor static func promptIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: promptedKey), !isNever else { return }
        UserDefaults.standard.set(true, forKey: promptedKey)
        let alert = NSAlert()
        alert.messageText = "Keep the island visible in fullscreen?"
        alert.informativeText =
            "macOS hides the menu bar, and the island with it, in fullscreen apps. Set “Automatically hide and show the menu bar” to Never in Control Center settings to keep it visible. You can come back to this in NotchBot Settings."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn { openSystemSettings() }
    }
}
