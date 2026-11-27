import AppKit
import NotchbotCore
import SwiftUI

/// Renders the island views offscreen with demo data (`--snapshot <dir>`). The system draws the real island's shape
/// and places the regions, so the frame here is an approximation: a black, continuous-cornered panel.
@MainActor
enum IslandSnapshots {
    static func render(sessions: [AgentSession], to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let quota = QuotaState(
            fiveHour: QuotaWindow(usedPercent: 82, resetsAt: Date().addingTimeInterval(2 * 3600 + 5 * 60)),
            sevenDay: QuotaWindow(usedPercent: 12, resetsAt: Date().addingTimeInterval(5 * 86_400)))
        let question = NotchActivityState.make(sessions: sessions, quota: quota)
        // Without the question, the subagent's permission request becomes the featured card.
        let permission = NotchActivityState.make(sessions: sessions.filter { $0.pending?.isQuestion != true }, quota: quota)
        let working = NotchActivityState.make(
            sessions: sessions.filter { $0.status == .working || $0.status == .compacting }, quota: quota)
        let idle = NotchActivityState.make(sessions: [], quota: quota)
        let page2 = NotchActivityState.make(sessions: sessions.filter { $0.pending == nil }, quota: quota, page: 1)
        // The island size setting at its largest step: bigger type, two session cards per page.
        let larger = Preferences.IslandSize.larger
        var large = NotchActivityState.make(
            sessions: sessions.filter { $0.pending == nil }, quota: quota, maxRows: larger.maxRows)
        large.scale = larger.scale
        for (name, st) in [
            ("expanded-question", question), ("expanded-permission", permission), ("expanded-working", working),
            ("expanded-page-2", page2), ("expanded-idle", idle), ("expanded-larger", large),
        ] {
            write(expanded(st), dir.appendingPathComponent("\(name).png"))
        }
        for (name, st) in [("compact-needs-you", question), ("compact-working", working), ("compact-idle", idle)] {
            write(compact(st), dir.appendingPathComponent("\(name).png"))
        }
        print("wrote snapshots to \(dir.path)")
    }

    private static func expanded(_ st: NotchActivityState) -> some View {
        IslandExpanded(state: st).islandScale(st.scale).padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 20).frame(width: 400)
            .background(RoundedRectangle(cornerRadius: 44, style: .continuous).fill(.black))
            .padding(24).background(Color(white: 0.35))
            .environment(\.colorScheme, .dark)
    }

    private static func compact(_ st: NotchActivityState) -> some View {
        HStack {
            IslandCompactLeading(state: st)
            Spacer()
            IslandCompactTrailing(state: st)
        }
        .padding(.horizontal, 12).frame(width: 210, height: 38)
        .background(Capsule().fill(.black))
        .padding(24).background(Color(white: 0.35))
        .environment(\.colorScheme, .dark)
    }

    private static func write(_ view: some View, _ url: URL) {
        let r = ImageRenderer(content: view)
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: url)
    }
}
