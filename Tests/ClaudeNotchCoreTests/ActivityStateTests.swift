import Foundation
import Testing

@testable import ClaudeNotchCore

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
}
