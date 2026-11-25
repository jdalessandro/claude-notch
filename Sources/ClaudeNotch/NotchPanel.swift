import AppKit
import ClaudeNotchCore
import SwiftUI

/// Where the hardware notch is, in screen points. On displays without one we draw a virtual notch.
struct NotchGeometry: Equatable {
    var screen: NSScreen
    var notchWidth: CGFloat  // hardware cutout width (+ small margin so we fully cover it)
    var notchHeight: CGFloat  // reserved height = safe-area inset
    var hasHardwareNotch: Bool
    /// Floating Dynamic-Island style (pill detached from the top edge) vs. classic attached notch.
    var floating: Bool
    /// Gap between screen top and the pill; the island is ~19% of the reserved band on this hardware.
    var topGap: CGFloat { floating ? (notchHeight * 0.19).rounded() : 0 }
    var islandHeight: CGFloat { max(notchHeight - topGap, 24) }

    /// nil only while the system reports no screens (display reconfiguration, sleep): callers keep the old layout.
    static func current(floating: Bool = true) -> NotchGeometry? {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first else {
            return nil
        }
        if screen.safeAreaInsets.top > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            return .init(
                screen: screen, notchWidth: screen.frame.width - l.width - r.width + 14,
                notchHeight: screen.safeAreaInsets.top, hasHardwareNotch: true, floating: floating)
        }
        return .init(screen: screen, notchWidth: 0, notchHeight: 32, hasHardwareNotch: false, floating: true)
    }
}

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }  // lets buttons/hover work; panel is non-activating
    override var canBecomeMain: Bool { false }
    /// Allow the frame to sit over the menu bar / notch band.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
final class NotchController {
    let model: AppModel
    private(set) var geometry: NotchGeometry
    private let panel: NotchPanel
    private let host: NSHostingView<NotchRootView>
    private var contentSize = CGSize(width: 300, height: 40)  // final (non-animated) size incl. top gap
    private var gate = HoverGate()
    private var pollTimer: Timer?

    init(model: AppModel) {
        self.model = model
        // A display is always present when the app is launched by a logged-in user.
        geometry = NotchGeometry.current(floating: model.prefs.islandStyle == .floating)!
        panel = NotchPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .statusBar + 2
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = false; panel.hidesOnDeactivate = false

        host = NSHostingView(rootView: NotchRootView(model: model, geometry: geometry, onSize: { _ in }))
        host.sizingOptions = []
        panel.contentView = host
        host.rootView = makeRoot()
        model.onExpandedChange = { [weak self] _ in self?.expandedChanged() }
        model.onPreferencesChanged = { [weak self] in self?.preferencesChanged() }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.screensChanged() }
        }
        layout()
        panel.orderFrontRegardless()
        startHoverTracking()
    }

    private func makeRoot() -> NotchRootView {
        NotchRootView(model: model, geometry: geometry) { [weak self] size in self?.contentChanged(size) }
    }

    // MARK: hover
    //
    // Hover comes from the real pointer position tested against the island's *final* rectangle, then
    // debounced by `HoverGate`. Reading hover off the animating SwiftUI shape made the island oscillate
    // (open -> shape moves -> "exit" -> close -> "enter" ...).

    private func startHoverTracking() {
        let t = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollPointer() }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    /// Screen-space region that counts as "on the island": padded, and extended up to the screen edge.
    private func hoverRect() -> NSRect {
        let f = geometry.screen.frame
        let w = contentSize.width, h = contentSize.height
        let padX: CGFloat = model.expanded ? 14 : 10, padY: CGFloat = model.expanded ? 14 : 8
        let minY = f.maxY - h - padY
        return NSRect(x: f.midX - w / 2 - padX, y: minY, width: w + 2 * padX, height: f.maxY - minY)
    }

    private func pollPointer() {
        let prefs = model.prefs
        let overIsland = hoverRect().contains(NSEvent.mouseLocation)
        gate.enterDelay = Double(prefs.hoverDelay.milliseconds) / 1000
        let hovering = gate.update(inside: prefs.expandOnHover && overIsland, now: Date())
        if hovering != model.hovering { model.hovering = hovering }
        model.reviewTick()
        // While collapsed, the transparent margins must not swallow clicks meant for the menu bar.
        let wantsEvents = model.expanded || overIsland
        if panel.ignoresMouseEvents == wantsEvents { panel.ignoresMouseEvents = !wantsEvents }
    }

    // MARK: layout

    private func preferencesChanged() {
        let floating = model.prefs.islandStyle == .floating
        if floating != geometry.floating, let g = NotchGeometry.current(floating: floating) {
            geometry = g
            host.rootView = makeRoot()
        }
        layout()
    }

    private func screensChanged() {
        guard let g = NotchGeometry.current(floating: model.prefs.islandStyle == .floating) else { return }  // keep the last layout
        geometry = g
        host.rootView = makeRoot()
        layout()
    }

    private func contentChanged(_ size: CGSize) { contentSize = size; applyFrame() }
    private func expandedChanged() { applyFrame() }

    /// Grow immediately; shrink only after the SwiftUI collapse has finished so nothing is clipped mid-animation.
    private func applyFrame() {
        if model.expanded {
            layout()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, !self.model.expanded else { return }; self.layout()
            }
        }
    }

    /// The window is a little larger than the visible shape so shadows are not clipped.
    private func layout() {
        let f = geometry.screen.frame
        let w = max(contentSize.width + 40, 200), h = contentSize.height + 24
        let r = NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h)
        if panel.frame != r { panel.setFrame(r, display: true) }
    }
}
