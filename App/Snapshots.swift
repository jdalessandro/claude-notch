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
        // The destructive request after its first Allow tap: the button reads "Confirm".
        let permissionId = permission.prompt?.requestId
        let confirm = NotchActivityState.make(
            sessions: sessions.filter { $0.pending?.isQuestion != true }, quota: quota, confirmingRequestId: permissionId)
        // An ordinary (not destructive) approval, for the green Allow.
        var allow = permission
        allow.prompt?.destructive = false
        allow.prompt?.text = "swift test --filter Retry"
        allow.prompt?.sessionScope = "swift test"
        let working = NotchActivityState.make(
            sessions: sessions.filter { $0.status == .working || $0.status == .compacting }, quota: quota)
        let idle = NotchActivityState.make(sessions: [], quota: quota)
        let page2 = NotchActivityState.make(sessions: sessions.filter { $0.pending == nil }, quota: quota, page: 1)
        // The island size setting at its largest step: bigger type, two session cards per page.
        let larger = Preferences.IslandSize.larger
        var large = NotchActivityState.make(
            sessions: sessions.filter { $0.pending == nil }, quota: quota, maxRows: larger.maxRows)
        large.scale = larger.scale
        var noLimits = NotchActivityState.make(sessions: sessions.filter { $0.pending == nil }, quota: nil)
        noLimits.page = 0
        var failed = noLimits
        failed.limitsNote = .failed
        let hooksOff = NotchActivityState.make(sessions: [], quota: nil, hooksInstalled: false)
        for (name, st) in [
            ("expanded-limits-unavailable", noLimits),
            ("expanded-limits-failed", failed), ("expanded-hooks-missing", hooksOff),
        ] {
            write(expanded(st), dir.appendingPathComponent("\(name).png"))
        }
        write(expanded(working, stale: true), dir.appendingPathComponent("expanded-stale.png"))
        // Every size step of the cards that crowd first, at the island's real width. A step whose content is wider than
        // the island is reported (and fails the run), so an overflow can't slip in unseen.
        let byKind: [(String, [AgentSession])] = [
            ("working", busy(sessions)),
            ("permission", sessions.filter { $0.pending?.isQuestion != true }),
            ("question", sessions),
            ("choices", sessions),
        ]
        var overflows: [String] = []
        for size in Preferences.IslandSize.allCases {
            for (kind, subset) in byKind {
                let ask = subset.first { $0.pending?.isQuestion == true }?.pending?.id.uuidString
                var st = NotchActivityState.make(
                    sessions: subset, quota: quota, maxRows: size.maxRows, choosing: kind == "choices" ? ask : nil)
                st.scale = size.scale
                if kind != "question" && kind != "choices" {
                    write(expanded(st), dir.appendingPathComponent("expanded-\(kind)-\(size.title.lowercased()).png"))
                }
                let w = contentWidth(of: st)
                if w > Self.bodyWidth + 0.5 {
                    overflows.append(
                        "\(kind) at \(size.title) (\(size.scale)x): content \(Int(w.rounded(.up)))pt, island \(Int(Self.bodyWidth))pt")
                }
            }
        }
        // The question's choices, opened from the card's "Answer".
        let choosing = NotchActivityState.make(
            sessions: sessions, quota: quota, choosing: sessions.first { $0.pending?.isQuestion == true }?.pending?.id.uuidString)
        // A session's subagent tree in place of the list: without a request card, and under one (an orange subagent).
        let working3 = sessions.filter { $0.pending == nil }
        let tree = NotchActivityState.make(sessions: working3, quota: quota, focus: "infra-tools")
        let treeAsking = NotchActivityState.make(
            sessions: sessions.filter { $0.pending?.isQuestion != true }, quota: quota, focus: "web-dashboard")
        for (name, st) in [
            ("expanded-subagents", tree), ("expanded-subagents-permission", treeAsking),
            ("expanded-question", question), ("expanded-question-choices", choosing), ("expanded-permission", permission),
            ("expanded-permission-confirm", confirm),
            ("expanded-permission-allow", allow),
            ("expanded-working", working),
            ("expanded-page-2", page2), ("expanded-idle", idle), ("expanded-larger", large),
        ] {
            write(expanded(st), dir.appendingPathComponent("\(name).png"))
        }
        for (name, st) in [("compact-needs-you", question), ("compact-working", working), ("compact-idle", idle)] {
            write(compact(st), dir.appendingPathComponent("\(name).png"))
        }
        print("wrote snapshots to \(dir.path)")
        if !overflows.isEmpty {
            print("OVERFLOW: content is wider than the island:\n  " + overflows.joined(separator: "\n  "))
            exit(1)
        }
    }

    /// The expanded island's width and what is left for the cards: the system draws the island at a fixed width (about
    /// 440pt on the notch Macs, measured from screenshots of the real island at both large steps, which are the same
    /// width at every size) and insets the bottom region by about 14pt a side before `Island.inset` is added.
    static let width: CGFloat = 440
    static let systemMargin: CGFloat = 14
    static var bodyWidth: CGFloat { width - 2 * (Island.inset + systemMargin) }

    /// Two sessions that are only working (no request), with timers of different widths: 0:39 and past the hour.
    private static func busy(_ sessions: [AgentSession]) -> [AgentSession] {
        guard var a = sessions.first(where: { $0.id == "payments-api" }) else { return [] }
        a.pending = nil
        a.status = .working
        a.gitBranch = "claude/island-colours"
        a.workingSince = Date().addingTimeInterval(-39)
        var b = a
        b.id = "web-dashboard-2"
        b.cwd = "/Users/you/code/web-dashboard-2"
        b.gitBranch = "claude/waiting-input-status"
        b.workingSince = Date().addingTimeInterval(-(3600 + 12 * 60 + 3))
        return [a, b]
    }

    /// The width the island's content asks for when offered `bodyWidth`: more than that means it overflows.
    private static func contentWidth(of st: NotchActivityState) -> CGFloat {
        let v = IslandBody(state: st).islandScale(st.scale).environment(\.colorScheme, .dark)
        return NSHostingController(rootView: v).sizeThatFits(in: CGSize(width: bodyWidth, height: 4000)).width
    }

    private static func expanded(_ st: NotchActivityState, stale: Bool = false) -> some View {
        IslandExpanded(state: st).environment(\.islandStale, stale).islandScale(st.scale)
            .padding(.horizontal, Island.inset + systemMargin).padding(.top, 22)
            .padding(.bottom, 20).frame(width: width)
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
