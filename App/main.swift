import AppKit
import ClaudeNotchCore
import SwiftUI

// Claude Notch — Claude Code's status as a macOS Live Activity (Dynamic Island).
//   ClaudeNotch            run normally (listens for hook events)
//   ClaudeNotch --demo     run with synthetic sessions (no hooks needed)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let settingsWindow = SettingsWindowController()
    let detailWindow = DetailWindowController()
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Starting a Live Activity needs the app in the foreground, so launch as a regular app first and become a
        // menu-bar-only agent once the activity is up.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        let demo = CommandLine.arguments.contains("--demo")
        model.onOpenSettings = { [weak self] in
            guard let self else { return }; self.settingsWindow.show(model: self.model)
        }
        model.onShowWindow = { [weak self] in
            guard let self else { return }; self.detailWindow.show(model: self.model)
        }
        IntentBridge.handler = { [weak self] action, sid, rid in self?.model.handleIntent(action, sessionId: sid, requestId: rid) }
        model.island.adoptExisting()
        model.start(demo: demo)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Claude Notch")
        let menu = NSMenu()
        menu.addItem(withTitle: "Sessions…", action: #selector(showWindow), keyEquivalent: "")
        menu.addItem(withTitle: "Show Island", action: #selector(showIsland), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Claude Notch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for i in menu.items where i.action != #selector(NSApplication.terminate(_:)) { i.target = self }
        item.menu = menu
        statusItem = item

        // A window makes the app frontmost, which starting the activity requires. Once the island is up, tuck away.
        detailWindow.show(model: model)
        Task { @MainActor in
            for _ in 0..<30 {
                try? await Task.sleep(for: .milliseconds(500))
                model.reconcile()
                if model.island.isLive { break }
            }
            if model.island.isLive, !CommandLine.arguments.contains("--regular") {
                detailWindow.hide()
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

    @objc func showWindow() { detailWindow.show(model: model) }
    @objc func showIsland() { model.showIsland() }
    @objc func openSettings() { settingsWindow.show(model: model) }
}

@MainActor
final class DetailWindowController {
    private var window: NSWindow?
    func show(model: AppModel) {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: DetailView(model: model)))
            w.title = "Claude Notch"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 460, height: 640))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
    func hide() { window?.orderOut(nil) }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
