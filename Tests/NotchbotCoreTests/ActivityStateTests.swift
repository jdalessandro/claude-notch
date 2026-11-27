import Foundation
import Testing

@testable import NotchbotCore

@Suite struct ActivityStateTests {
    func store(_ build: (inout SessionStore) -> Void) -> SessionStore {
        var s = SessionStore()
        build(&s)
        return s
    }

    @Test func emptyStoreIsIdle() {
        let st = NotchActivityState.make(sessions: [], quota: nil)
        #expect(st.phase == .idle && st.rows.isEmpty && st.prompt == nil)
    }

    @Test func idleStateKeepsLimitsAndResets() {
        let reset = Date().addingTimeInterval(3_600)
        let quota = QuotaState(fiveHour: QuotaWindow(usedPercent: 40, resetsAt: reset), sevenDay: QuotaWindow(usedPercent: 17))
        let st = NotchActivityState.make(sessions: [], quota: quota)
        #expect(st.fiveHour == 0.4 && st.fiveHourReset == reset && st.weekly == 0.17 && st.weeklyReset == nil)
    }

    @Test func workingSessionsSummarize() {
        let s = store {
            _ = $0.apply(ev("UserPromptSubmit", sid: "a") { $0.prompt = "go" })
            _ = $0.apply(ev("UserPromptSubmit", sid: "b") { $0.prompt = "go" })
        }
        let st = NotchActivityState.make(sessions: s.active, quota: nil)
        #expect(st.phase == .working && st.headline == "2 working" && st.rows.count == 2)
        #expect(st.rows.allSatisfy { $0.kind == .working && $0.since != nil })
    }

    @Test func approvalCarriesRequestIdAndCommand() throws {
        let s = store {
            _ = $0.apply(ev("UserPromptSubmit", sid: "a") { $0.prompt = "go" })
            _ = $0.apply(
                ev("PermissionRequest", sid: "a", expectsReply: true) {
                    $0.toolName = "Bash"; $0.toolInput = .object(["command": .string("rm -rf build")])
                })
        }
        let st = NotchActivityState.make(sessions: s.active, quota: nil)
        let ap = try #require(st.prompt)
        #expect(st.phase == .needsYou && st.needsYou == 1 && st.rows.isEmpty, "the featured session is not repeated as a row")
        #expect(ap.sessionId == "a" && ap.tool == "Bash" && ap.text.contains("rm -rf build") && !ap.isQuestion && ap.canAnswer)
        #expect(s.sessions["a"]?.isAnswerable(requestId: ap.requestId) == true)
    }

    @Test func staleRequestIdIsNotAnswerable() throws {
        let s = store {
            _ = $0.apply(
                ev("PermissionRequest", sid: "a", expectsReply: true) {
                    $0.toolName = "Bash"; $0.toolInput = .object(["command": .string("ls")])
                })
        }
        let session = try #require(s.sessions["a"])
        #expect(!session.isAnswerable(requestId: UUID().uuidString))
        #expect(!session.isAnswerable(requestId: "garbage"))
    }

    @Test func questionsAreNotApprovals() throws {
        let q = try JSONDecoder().decode(
            JSONValue.self, from: Data(#"{"questions":[{"question":"Ship it?","options":[{"label":"Yes"}]}]}"#.utf8))
        let s = store {
            _ = $0.apply(
                ev("PermissionRequest", sid: "a", expectsReply: true) {
                    $0.toolName = "AskUserQuestion"; $0.toolInput = q
                })
        }
        let st = NotchActivityState.make(sessions: s.active, quota: nil)
        let p = try #require(st.prompt)
        #expect(p.isQuestion && p.text == "Ship it?" && p.options == ["Yes"] && p.moreQuestions == 0)
    }

    @Test func secondRequestIsAnswerableInline() throws {
        let s = store { st in
            for sid in ["a", "b"] {
                _ = st.apply(
                    ev("PermissionRequest", sid: sid, expectsReply: true) {
                        $0.toolName = "Bash"; $0.toolInput = .object(["command": .string("ls")])
                    })
            }
        }
        let st = NotchActivityState.make(sessions: s.active, quota: nil)
        let row = try #require(st.rows.first)
        #expect(st.prompt != nil && row.kind == .approval && row.id != st.prompt?.sessionId)
        #expect(s.sessions[row.id]?.isAnswerable(requestId: row.requestId ?? "") == true)
    }

    @Test func reviewDetailIsPlainText() throws {
        let s = store {
            _ = $0.apply(ev("UserPromptSubmit", sid: "a") { $0.prompt = "go" })
            _ = $0.apply(ev("Stop", sid: "a") { $0.lastAssistantMessage = "Merged **main** into [PR 2](https://x.y/2)" })
        }
        let st = NotchActivityState.make(sessions: s.active, quota: nil)
        #expect(st.rows.first?.kind == .review && st.rows.first?.detail == "Merged main into PR 2")
    }

    @Test func overflowIsCountedAndQuotaPassesThrough() {
        let s = store { st in
            for i in 0..<6 { _ = st.apply(ev("UserPromptSubmit", sid: "s\(i)") { $0.prompt = "go" }) }
        }
        let quota = QuotaState(fiveHour: QuotaWindow(usedPercent: 82), sevenDay: QuotaWindow(usedPercent: 12))
        let st = NotchActivityState.make(sessions: s.active, quota: quota)
        #expect(st.rows.count == NotchActivityState.maxRows && st.more == 6 - NotchActivityState.maxRows)
        #expect(st.pages == 2 && st.page == 0)  // 6 sessions, 3 per page
        #expect(st.fiveHour == 0.82 && st.weekly == 0.12)
    }

    @Test func pagesShowEverySessionOnceAndWrap() {
        let s = store { st in
            for i in 0..<5 { _ = st.apply(ev("UserPromptSubmit", sid: "s\(i)") { $0.prompt = "go" }) }
        }
        let first = NotchActivityState.make(sessions: s.active, quota: nil)
        let n = first.pages
        #expect(n == (5 + NotchActivityState.maxRows - 1) / NotchActivityState.maxRows)
        let pages = (0..<n).map { NotchActivityState.make(sessions: s.active, quota: nil, page: $0) }
        #expect(pages.map(\.page) == Array(0..<n))
        let ids = pages.flatMap { $0.rows.map(\.id) }
        #expect(ids.count == 5 && Set(ids).count == 5, "every session on exactly one page")
        #expect(NotchActivityState.make(sessions: s.active, quota: nil, page: n).page == 0)
        #expect(NotchActivityState.make(sessions: s.active, quota: nil, page: -1).page == n - 1)
    }

    @Test func stateStaysWithinTheByteBudgetEvenWithHugeText() {
        let huge = String(repeating: "x", count: 5_000)
        let s = store { st in
            for i in 0..<10 {
                _ = st.apply(ev("UserPromptSubmit", sid: "s\(i)") { $0.prompt = huge })
                _ = st.apply(
                    ev("PermissionRequest", sid: "s\(i)", expectsReply: true) {
                        $0.toolName = String(repeating: "T", count: 200); $0.toolInput = .object(["command": .string(huge)])
                    })
            }
        }
        let st = NotchActivityState.make(sessions: s.active, quota: nil)
        #expect(st.encodedSize < NotchActivityState.byteBudget)
    }

    @Test func roundTripsThroughCodable() throws {
        let s = store { _ = $0.apply(ev("UserPromptSubmit", sid: "a") { $0.prompt = "go" }) }
        let st = NotchActivityState.make(sessions: s.active, quota: nil)
        let back = try JSONDecoder().decode(NotchActivityState.self, from: JSONEncoder().encode(st))
        #expect(back == st)
    }

    func approval(_ sid: String) -> (inout SessionStore) -> Void {
        { st in
            _ = st.apply(ev("UserPromptSubmit", sid: sid) { $0.prompt = "go" })
            _ = st.apply(
                ev("PermissionRequest", sid: sid, expectsReply: true) {
                    $0.toolName = "Bash"; $0.toolInput = .object(["command": .string("ls")])
                })
        }
    }

    @Test func offPageNeedCountsRequestsOnOtherPages() {
        // a and d wait on approval, b and c work. One row per page under the featured prompt.
        let s = store { st in
            approval("a")(&st)
            _ = st.apply(ev("UserPromptSubmit", sid: "b") { $0.prompt = "go" })
            _ = st.apply(ev("UserPromptSubmit", sid: "c") { $0.prompt = "go" })
            approval("d")(&st)
        }
        let pages = (0..<3).map { NotchActivityState.make(sessions: s.active, quota: nil, page: $0) }
        #expect(pages.allSatisfy { $0.pages == 3 && $0.rows.count == 1 })
        // Page 0 shows the other approval (urgent rows sort first), so nothing needing you is hidden; on the others it is.
        #expect(pages.map(\.offPageNeed) == [0, 1, 1])
    }

    @Test func offPageNeedIsZeroOnASinglePage() {
        let s = store {
            approval("a")(&$0); _ = $0.apply(ev("UserPromptSubmit", sid: "b") { $0.prompt = "go" })
        }
        #expect(NotchActivityState.make(sessions: s.active, quota: nil).offPageNeed == 0)
    }

    @Test func offPageNeedIgnoresFinishedReviews() {
        let s = store { st in
            approval("a")(&st)
            for i in 0..<3 {
                _ = st.apply(ev("UserPromptSubmit", sid: "w\(i)") { $0.prompt = "go" })
            }
        }
        let st = NotchActivityState.make(sessions: s.active, quota: nil)
        #expect(st.pages > 1 && st.offPageNeed == 0)
    }

    @Test func offPageNeedNeverExceedsTheHeaderAndAgreesAcrossPages() {
        // approvals, a failure, a review and workers: every page's hint stays within the header's count.
        let s = store { st in
            approval("a")(&st); approval("b")(&st)
            _ = st.apply(ev("UserPromptSubmit", sid: "f") { $0.prompt = "go" })
            _ = st.apply(ev("StopFailure", sid: "f"))
            for i in 0..<3 { _ = st.apply(ev("UserPromptSubmit", sid: "w\(i)") { $0.prompt = "go" }) }
        }
        for p in 0..<6 {
            let st = NotchActivityState.make(sessions: s.active, quota: nil, page: p)
            #expect(st.offPageNeed <= st.needsYou, "page \(p)")
            let shownNeeds = st.rows.filter { [.approval, .question, .input, .failed].contains($0.kind) }.count
            let featured = st.prompt == nil ? 0 : 1
            #expect(st.offPageNeed + shownNeeds + featured == s.active.filter { $0.status.needsAttention }.count, "page \(p)")
        }
    }

    @Test func failedSessionsOnOtherPagesCountAsWaiting() {
        let s = store { st in
            for i in 0..<4 { _ = st.apply(ev("UserPromptSubmit", sid: "w\(i)") { $0.prompt = "go" }) }
            _ = st.apply(ev("StopFailure", sid: "w0"))
        }
        #expect(s.active.contains { $0.status == .failed }, "the fixture really has a failed session")
        let all = (0..<2).map { NotchActivityState.make(sessions: s.active, quota: nil, maxRows: 2, page: $0) }
        // The failed session is on exactly one page; the other page's hint counts it, its own page's does not.
        #expect(all.map(\.offPageNeed).sorted() == [0, 1])
        #expect(all.map(\.needsYou).allSatisfy { $0 == 1 })
    }

    @Test func needPagePointsAtTheNearestWaitingPageAndWraps() {
        let s = store { st in
            approval("a")(&st)
            for i in 0..<3 { _ = st.apply(ev("UserPromptSubmit", sid: "w\(i)") { $0.prompt = "go" }) }
            approval("b")(&st)
        }
        let p0 = NotchActivityState.make(sessions: s.active, quota: nil, page: 0)
        let p2 = NotchActivityState.make(sessions: s.active, quota: nil, page: 2)
        if p0.offPageNeed > 0 { #expect(p0.needPage != nil && p0.needPage != p0.page) }
        let waitingPages = (0..<p2.pages).filter { p in
            NotchActivityState.make(sessions: s.active, quota: nil, page: p).rows.contains { $0.kind == .approval }
        }
        #expect(!waitingPages.isEmpty)
        // Jumping to the target shows a session waiting on you.
        for p in 0..<p2.pages {
            let st = NotchActivityState.make(sessions: s.active, quota: nil, page: p)
            guard let t = st.needPage else { #expect(st.offPageNeed == 0); continue }
            let there = NotchActivityState.make(sessions: s.active, quota: nil, page: t)
            #expect(there.rows.contains { $0.kind == .approval || $0.kind == .failed || $0.kind == .input })
        }
    }

    @Test func noHintWhenNothingWaitsElsewhere() {
        let s = store { st in
            for i in 0..<4 { _ = st.apply(ev("UserPromptSubmit", sid: "w\(i)") { $0.prompt = "go" }) }
        }
        let st = NotchActivityState.make(sessions: s.active, quota: nil, maxRows: 2)
        #expect(st.pages > 1 && st.offPageNeed == 0 && st.needPage == nil)
    }

    @Test func approvalOnAnotherPageIsCounted() {
        let s = store { st in
            approval("a")(&st)
            _ = st.apply(ev("UserPromptSubmit", sid: "w") { $0.prompt = "go" })
            approval("b")(&st)
        }
        // a is answerable and featured; w and b are rows, one per page. Whichever page is shown, the other row's need
        // is counted only when it needs you.
        let p0 = NotchActivityState.make(sessions: s.active, quota: nil, page: 0)
        let p1 = NotchActivityState.make(sessions: s.active, quota: nil, page: 1)
        let needRows = [p0, p1].map { $0.rows.filter { $0.kind == .approval }.count }
        #expect(p0.offPageNeed + needRows[0] == 1 && p1.offPageNeed + needRows[1] == 1)
    }

    @Test func limitsNoteAndHooksFlagPassThroughAndStayOutOfTheWayByDefault() throws {
        let plain = NotchActivityState.make(sessions: [], quota: nil)
        #expect(plain.limitsNote == nil && !plain.hooksMissing && plain.limitsUnknown)
        let st = NotchActivityState.make(sessions: [], quota: nil, limitsNote: .failed, hooksInstalled: false)
        #expect(st.limitsNote == .failed && st.hooksMissing)
        let back = try JSONDecoder().decode(NotchActivityState.self, from: JSONEncoder().encode(st))
        #expect(back == st)
        // nil notes are omitted from the payload.
        #expect(!String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("limitsNote"))
    }

    @Test func newFieldsKeepTheBudget() {
        let huge = String(repeating: "x", count: 5_000)
        let s = store { st in
            for i in 0..<10 {
                _ = st.apply(ev("UserPromptSubmit", sid: "s\(i)") { $0.prompt = huge })
                approval("s\(i)")(&st)
            }
        }
        let st = NotchActivityState.make(sessions: s.active, quota: nil, limitsNote: .refreshing, hooksInstalled: false)
        #expect(st.encodedSize < NotchActivityState.byteBudget)
    }

    /// A session with `n` subagents whose names and tool details are far longer than the island can show.
    func sessionWithSubagents(_ n: Int, asking: Bool = false) -> SessionStore {
        let huge = String(repeating: "x", count: 500)
        return store { st in
            _ = st.apply(ev("UserPromptSubmit", sid: "tree") { $0.prompt = huge })
            for i in 0..<n {
                _ = st.apply(
                    ev("PreToolUse", sid: "tree") {
                        $0.toolName = "Task"; $0.toolInput = .object(["description": .string(huge)])
                    })
                _ = st.apply(
                    ev("SubagentStart", sid: "tree") {
                        $0.agentId = "a\(i)"; $0.agentType = String(repeating: "T", count: 80)
                    })
                _ = st.apply(
                    ev("PreToolUse", sid: "tree") {
                        $0.agentId = "a\(i)"; $0.agentType = "Explore"; $0.toolName = String(repeating: "G", count: 90)
                        $0.toolInput = .object(["pattern": .string(huge)])
                    })
            }
            if asking {
                _ = st.apply(
                    ev("PermissionRequest", sid: "tree", expectsReply: true) {
                        $0.agentId = "a\(n - 1)"; $0.agentType = "Explore"; $0.toolName = "Bash"
                        $0.toolInput = .object(["command": .string(huge)])
                    })
            }
        }
    }

    @Test func focusedTreeIsCappedAndStaysWithinTheByteBudget() {
        for asking in [false, true] {
            let s = sessionWithSubagents(40, asking: asking)
            let st = NotchActivityState.make(sessions: s.active, quota: nil, focus: "tree")
            let f = try! #require(st.focus)
            let cap = asking ? NotchActivityState.maxTreeLinesWithPrompt : NotchActivityState.maxTreeLines
            #expect(f.lines.count == cap && f.lines.first?.name == "Main")
            #expect(f.more == 40 - (cap - 1) && f.total == 40 && f.running == 40)
            #expect(f.lines.allSatisfy { $0.name.count <= 16 && $0.detail.count <= 44 })
            #expect(st.rows.isEmpty, "the tree replaces the session rows")
            #expect(st.encodedSize < NotchActivityState.byteBudget)
        }
    }

    @Test func noHintWhileTheSubagentTreeReplacesTheRows() {
        // The tree empties `rows`; nothing is "on another page" then, so the hint must not claim sessions.
        let s = sessionWithSubagents(5, asking: true)
        let st = NotchActivityState.make(sessions: s.active, quota: nil, focus: "tree")
        #expect(st.rows.isEmpty && st.offPageNeed == 0 && st.needPage == nil)
    }

    @Test func aSubagentWaitingOnYouLeadsTheTreeAndIsAmber() {
        let s = sessionWithSubagents(10, asking: true)
        let f = try! #require(NotchActivityState.make(sessions: s.active, quota: nil, focus: "tree").focus)
        #expect(f.lines[0].state == .running, "the main agent isn't the one waiting")
        #expect(f.lines[1].state == .waiting && f.lines[1].detail.hasPrefix("Needs approval"))
        #expect(f.lines.dropFirst(2).allSatisfy { $0.state == .running })
    }

    @Test func treeListsRunningBeforeDoneAndLabelsEachLine() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let s = store { st in
            _ = st.apply(ev("UserPromptSubmit", sid: "t", t: 0) { $0.prompt = "go" })
            _ = st.apply(
                ev("SubagentStart", sid: "t", t: 1) {
                    $0.agentId = "d"; $0.agentType = "Plan"
                })
            _ = st.apply(
                ev("SubagentStop", sid: "t", t: 5) {
                    $0.agentId = "d"; $0.lastAssistantMessage = "Planned"
                })
            _ = st.apply(
                ev("SubagentStart", sid: "t", t: 6) {
                    $0.agentId = "r"; $0.agentType = "Explore"
                })
            _ = st.apply(
                ev("PreToolUse", sid: "t", t: 7) {
                    $0.agentId = "r"; $0.agentType = "Explore"; $0.toolName = "Grep"; $0.toolInput = .object(["pattern": .string("login")])
                })
        }
        let f = try! #require(NotchActivityState.make(sessions: s.active, quota: nil, focus: "t").focus)
        #expect(f.lines.map(\.name) == ["Main", "Explore", "Plan"])
        #expect(f.lines.map(\.state) == [.running, .running, .done])
        let running = f.lines[1]
        let label = running.accessibilityLabel(now: (running.since ?? t0).addingTimeInterval(42))
        #expect(label.hasPrefix("Explore subagent, running, Grep") && label.hasSuffix("42 seconds"))
        #expect(f.lines[2].accessibilityLabel().contains("Plan subagent, done, Planned"))
    }

    @Test func focusFallsBackToTheListWhenThereIsNothingToShow() {
        let s = store { _ = $0.apply(ev("UserPromptSubmit", sid: "a") { $0.prompt = "go" }) }
        #expect(NotchActivityState.make(sessions: s.active, quota: nil, focus: "a").focus == nil, "no subagents")
        #expect(NotchActivityState.make(sessions: s.active, quota: nil, focus: "gone").focus == nil)
        #expect(NotchActivityState.make(sessions: s.active, quota: nil, focus: "a").rows.count == 1)
    }
}
