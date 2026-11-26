import ActivityKit
import SwiftUI
import os

private let log = Logger(subsystem: "dev.claudenotch.live", category: "app")

@MainActor @Observable final class Model {
    var status = "idle"
    var enabled = ActivityAuthorizationInfo().areActivitiesEnabled
    var activity: Activity<NotchAttributes>?

    func note(_ s: String) { status = s; log.notice("\(s, privacy: .public)") }

    func start(style: ActivityStyle) {
        let state = NotchAttributes.ContentState(
            agents: 3, needsYou: 1, headline: "payments-api needs you", detail: "Bash: npm install --save-dev vitest",
            approvalPending: true)
        do {
            activity = try Activity.request(
                attributes: NotchAttributes(title: "Claude Notch"),
                content: .init(state: state, staleDate: nil), pushType: nil, style: style)
            note("started \(style) id=\(activity?.id ?? "?")")
        } catch {
            let e = error as NSError
            note("start failed: \(String(reflecting: error)) domain=\(e.domain) code=\(e.code) info=\(e.userInfo)")
        }
    }

    func update() async {
        guard let activity else { return note("nothing to update") }
        let s = NotchAttributes.ContentState(
            agents: 3, needsYou: 0, headline: "payments-api working", detail: "swift test", approvalPending: false)
        await activity.update(.init(state: s, staleDate: nil))
        note("updated")
    }

    func update2(n: Int = 0) async {
        guard let activity else { return note("nothing to update") }
        let s = NotchAttributes.ContentState(
            agents: 5, needsYou: 2, headline: "web-dashboard needs you", detail: "Bash: rm -rf node_modules (\(n))", approvalPending: true)
        await activity.update(.init(state: s, staleDate: nil), alertConfiguration: AlertConfiguration(title: "Needs you", body: "web-dashboard", sound: .default))
        note("updated2 (with alert)")
    }

    func end() async {
        guard let activity else { return note("nothing to end") }
        await activity.end(nil, dismissalPolicy: .immediate)
        self.activity = nil
        note("ended")
    }
}

@main struct NotchLiveApp: App {
    @State private var m = Model()
    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 12) {
                Text("Live Activities enabled: \(m.enabled ? "yes" : "no")")
                HStack {
                    Button("Start (standard)") { m.start(style: .standard) }
                    Button("Start (transient)") { m.start(style: .transient) }
                    Button("Update") { Task { await m.update() } }
                    Button("End") { Task { await m.end() } }
                }
                Text(m.status).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            }
            .padding(20).frame(minWidth: 520)
            .task {
                if CommandLine.arguments.contains("--start") { m.start(style: .standard) }
                if CommandLine.arguments.contains("--pulse") {
                    // Re-expand the island with an alert every 12 s so a person can press Allow/Deny.
                    m.start(style: .standard)
                    for i in 0..<10 {
                        try? await Task.sleep(for: .seconds(12))
                        await m.update2(n: i)
                    }
                    await m.end()
                }
                if CommandLine.arguments.contains("--seq") {
                    // Start in the foreground, then keep updating while the app is in the background.
                    m.start(style: .standard)
                    try? await Task.sleep(for: .seconds(10))
                    await m.update()
                    try? await Task.sleep(for: .seconds(10))
                    await m.update2()
                }
                for await e in ActivityAuthorizationInfo().activityEnablementUpdates { m.enabled = e }
            }
        }
        .defaultSize(width: 560, height: 160)
    }
}
