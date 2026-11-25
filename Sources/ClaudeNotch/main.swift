import AppKit
import SwiftUI

// Claude Notch — a Dynamic-Island-style overlay for the MacBook notch that tracks Claude Code agents.
//   ClaudeNotch            run normally (listens for hook events)
//   ClaudeNotch --demo     run with synthetic sessions (UI preview, no hooks needed)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    var controller: NotchController?
    let settingsWindow = SettingsWindowController()
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let demo = CommandLine.arguments.contains("--demo")
        controller = NotchController(model: model)
        model.onOpenSettings = { [weak self] in
            guard let self else { return }; self.settingsWindow.show(model: self.model)
        }
        model.start(demo: demo)

        // Menu-bar fallback so the app is reachable on displays without a notch or when hidden.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Claude Notch")
        let menu = NSMenu()
        menu.addItem(withTitle: "Toggle Notch Panel", action: #selector(togglePin), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Claude Notch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items.forEach { $0.target = ($0.action == #selector(togglePin) || $0.action == #selector(openSettings)) ? self : nil }
        item.menu = menu
        statusItem = item
    }

    @objc func togglePin() { model.pinned.toggle() }
    @objc func openSettings() { settingsWindow.show(model: model) }
}

// --snapshot <dir>: render collapsed + expanded demo UI to PNGs (no screen-recording permission needed).
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    let dir = CommandLine.arguments[i + 1]
    MainActor.assumeIsolated { renderSnapshots(to: dir) }
    exit(0)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()

@MainActor
func renderSnapshots(to dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    // Isolated defaults so rendering snapshots can never touch the real preferences.
    let suite = UserDefaults(suiteName: "claude-notch.snapshot")!
    suite.removePersistentDomain(forName: "claude-notch.snapshot")
    let model = AppModel(defaults: suite)
    model.snapshotMode = true
    model.start(demo: true)
    let defaultGeo = NotchGeometry(screen: NSScreen.screens[0], notchWidth: 73, notchHeight: 40, hasHardwareNotch: true, floating: true)
    func shot(_ name: String, height: CGFloat, geometry: NotchGeometry? = nil, showCutout: Bool = false) {
        let geo = geometry ?? defaultGeo
        model.reconcile()
        let view = NotchRootView(model: model, geometry: geo) { _ in }
        let bg = LinearGradient(
            colors: [Color(red: 0.35, green: 0.45, blue: 0.65), Color(red: 0.75, green: 0.62, blue: 0.6)], startPoint: .top,
            endPoint: .bottom)
        let r = ImageRenderer(
            content: ZStack {
                bg;
                view.frame(width: 600, height: height, alignment: .top)
                    .overlay(alignment: .top) {
                        // Debug aid: the hardware cutout (incl. its margin) drawn in red, to see any overlap.
                        if showCutout {
                            Rectangle().fill(Color.red.opacity(0.35)).frame(width: geo.notchWidth, height: geo.notchHeight)
                        }
                    }
            }.frame(width: 600, height: height))
        r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        {
            try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
    }
    model.autoExpandUntil = .distantPast
    model.pinned = true
    model.settings.prefs.expandedMode = .compact
    shot("expanded-compact", height: 520)
    model.settings.prefs.expandedMode = .detailed
    shot("expanded-needs-you", height: 1500)
    // Resolve the request and let the subagent finish so the "review / working / idle" mix is visible.
    model.store.resolvePermission("web-dashboard", allowed: true)
    model.expandedSubagents.insert("infra-tools")  // show the explorable subagent tree
    model.store.markSeen("web-dashboard")
    shot("expanded-mixed", height: 1500)
    model.pinned = false
    model.store.markSeen("docs-site")
    shot("collapsed", height: 120)
    // Safe-zone verification (debug): render both layouts with the cutout drawn in red, at the real cutout width and
    // at a much wider one, to confirm no header text ever runs underneath it.
    if ProcessInfo.processInfo.environment["CLAUDE_NOTCH_SNAPSHOT_DEBUG"] != nil {
        let wide = NotchGeometry(screen: NSScreen.screens[0], notchWidth: 150, notchHeight: 40, hasHardwareNotch: true, floating: true)
        model.pinned = true
        model.settings.prefs.expandedMode = .compact
        shot("debug-compact", height: 200, showCutout: true)
        shot("debug-compact-wide-cutout", height: 200, geometry: wide, showCutout: true)
        model.settings.prefs.expandedMode = .detailed
        shot("debug-detailed", height: 200, showCutout: true)
        shot("debug-detailed-wide-cutout", height: 200, geometry: wide, showCutout: true)
    }
}
