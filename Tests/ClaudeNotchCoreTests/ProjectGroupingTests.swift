import Foundation
import Testing

@testable import ClaudeNotchCore

private func session(_ id: String, _ cwd: String, _ status: AgentStatus = .done) -> AgentSession {
    var s = AgentSession(id: id, cwd: cwd, startedAt: Date(timeIntervalSince1970: 0), lastEventAt: Date(timeIntervalSince1970: 0))
    s.status = status
    return s
}

@Suite struct ProjectGroupingTests {
    @Test func worktreesJoinTheirRepository() {
        let a = session("a", "/Code/agent-sandbox")
        let b = session("b", "/Code/agent-sandbox/.claude/worktrees/supervision-f4dea3")
        let c = session("c", "/Code/practicum")
        let groups = ProjectGrouping.group([a, b, c])
        #expect(groups.map(\.name) == ["agent-sandbox", "practicum"])
        #expect(groups[0].sessionCount == 2)
    }

    @Test func scratchWorkspacesShareOneGroup() {
        let a = session("a", "/Users/x/Library/Application Support/Claude/scratch-workspaces/1/2/scratch-a")
        let b = session("b", "/Users/x/Library/Application Support/Claude/scratch-workspaces/3/4/scratch-b")
        let groups = ProjectGrouping.group([a, b])
        #expect(groups.count == 1)
        #expect(groups[0].name == "Scratch workspace")
    }

    @Test func groupsKeepTheOrderOfTheirMostUrgentSession() {
        // Input is already urgency-ordered, so the first session seen decides the group order.
        let groups = ProjectGrouping.group([
            session("a", "/Code/one", .needsPermission), session("b", "/Code/two", .working), session("c", "/Code/one", .done),
        ])
        #expect(groups.map(\.name) == ["one", "two"])
        #expect(groups[0].lead == .needsPermission)
        #expect(groups[0].needsAttention == 1)
        #expect(groups[1].running == 1)
    }

    @Test func childSessionsFollowTheirParent() {
        let p = session("p", "/Code/proj", .working)
        let other = session("o", "/Code/proj", .done)
        let child = session("c", "/Code/proj", .working)
        let idx = DesktopSessionIndex(sessions: ["c": .init(parentId: "p")])
        let rows = ProjectGrouping.group([p, other, child], desktop: idx)[0].rows
        #expect(rows.map(\.session.id) == ["p", "c", "o"])
        #expect(rows.map(\.isChild) == [false, true, false])
    }

    @Test func desktopOriginFolderOverridesCwd() {
        let s = session("a", "/tmp/elsewhere")
        let idx = DesktopSessionIndex(sessions: ["a": .init(originCwd: "/Code/real-project")])
        #expect(ProjectGrouping.group([s], desktop: idx)[0].name == "real-project")
    }

    @Test func openPRsAreSummed() {
        let idx = DesktopSessionIndex(sessions: ["a": .init(openPRs: 2), "b": .init(openPRs: 3)])
        let g = ProjectGrouping.group([session("a", "/Code/p"), session("b", "/Code/p")], desktop: idx)
        #expect(g[0].openPRs == 5)
    }

    @Test func indexReadsOnlyWhatItNeedsAndSkipsJunk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("idx-\(UUID().uuidString)/acct/org")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent()) }
        func write(_ name: String, _ json: String) throws {
            try json.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try write(
            "local_parent.json",
            #"{"sessionId":"local_parent","cliSessionId":"cli-p","cwd":"/Code/p","originCwd":"/Code/p","title":"T","prs":[{"state":"open"},{"state":"merged"}],"sideSessionNotes":[{"sessionId":"local_child"}]}"#
        )
        try write("local_child.json", #"{"sessionId":"local_child","cliSessionId":"cli-c","cwd":"/Code/p/.claude/worktrees/w"}"#)
        try write("local_archived.json", #"{"sessionId":"local_a","cliSessionId":"cli-a","isArchived":true}"#)
        try write("local_broken.json", "not json")
        try write("scheduled-tasks.json", "[]")
        let idx = DesktopSessionIndex.load(from: dir.deletingLastPathComponent().deletingLastPathComponent())
        #expect(idx.sessions.keys.sorted() == ["cli-c", "cli-p"])
        #expect(idx.sessions["cli-p"]?.openPRs == 1)
        #expect(idx.sessions["cli-p"]?.title == "T")
        #expect(idx.sessions["cli-c"]?.parentId == "cli-p")
    }

    @Test func missingDirectoryYieldsAnEmptyIndex() {
        #expect(DesktopSessionIndex.load(from: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")).sessions.isEmpty)
    }

    @Test func preferenceDefaultsOnAndSurvivesOldFiles() throws {
        #expect(Preferences().groupByProject)
        let old = try JSONDecoder().decode(Preferences.self, from: Data(#"{"expandOnHover":false}"#.utf8))
        #expect(old.groupByProject)
        let off = try JSONDecoder().decode(Preferences.self, from: Data(#"{"groupByProject":false}"#.utf8))
        #expect(!off.groupByProject)
    }
}
