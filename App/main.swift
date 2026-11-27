import AppKit
import NotchbotCore
import SwiftUI

// Notchbot — Claude Code's status as a macOS Live Activity (Dynamic Island).
//   Notchbot            run normally (listens for hook events)
//   Notchbot --demo     run with synthetic sessions (no hooks needed)
//   Notchbot --snapshot <dir>   render the island views with the demo data to PNGs and exit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let settingsWindow = SettingsWindowController()
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot") {
            let dir = CommandLine.arguments.indices.contains(i + 1) ? CommandLine.arguments[i + 1] : "snapshots"
            IslandSnapshots.render(sessions: model.loadDemoForSnapshot(), to: URL(fileURLWithPath: dir))
            exit(0)
        }
        // Starting a Live Activity needs the app in the foreground, so launch as a regular app first and become a
        // menu-bar-only agent once the activity is up.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        let demo = CommandLine.arguments.contains("--demo")
        model.onOpenSettings = { [weak self] in
            guard let self else { return }; self.settingsWindow.show(model: self.model)
        }
        IntentBridge.handler = { [weak self] action, sid, rid in self?.model.handleIntent(action, sessionId: sid, requestId: rid) }
        model.start(demo: demo)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let mark = ImageRenderer(
            content: RobotMark(tones: nil).fill(.black).frame(width: 16, height: 16))
        mark.scale = NSScreen.main?.backingScaleFactor ?? 2
        let icon = mark.nsImage
        icon?.isTemplate = true  // the menu bar tints it for light/dark
        icon?.accessibilityDescription = "NotchBot"
        item.button?.image = icon
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Island", action: #selector(showIsland), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit NotchBot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for i in menu.items where i.action != #selector(NSApplication.terminate(_:)) { i.target = self }
        item.menu = menu
        statusItem = item

        // Starting the activity needs the app frontmost; activating as a regular app is enough, no window. Once the
        // island is up (or has had its chance), tuck away; "Show Island" in the menu retries.
        Task { @MainActor in
            await model.island.resetExisting()
            for _ in 0..<30 {
                try? await Task.sleep(for: .milliseconds(500))
                model.reconcile()
                if model.island.isLive { break }
            }
            if !CommandLine.arguments.contains("--regular") {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        // End the activity so no stale island is left behind; the next launch starts a fresh one.
        let sem = DispatchSemaphore(value: 0)
        let host = model.island
        Task { @MainActor in
            await host.end(); sem.signal()
        }
        _ = sem.wait(timeout: .now() + 1)
    }

    @objc func showIsland() { model.showIsland() }
    @objc func openSettings() { settingsWindow.show(model: model) }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
