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
        #expect(st.phase == .idle && st.rows.isEmpty && st.approval == nil)
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
        let ap = try #require(st.approval)
        #expect(st.phase == .needsYou && st.needsYou == 1 && st.rows.first?.kind == .approval)
        #expect(ap.sessionId == "a" && ap.tool == "Bash" && ap.command.contains("rm -rf build"))
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
        #expect(st.rows.first?.kind == .question && st.approval == nil)
    }

    @Test func overflowIsCountedAndQuotaPassesThrough() {
        let s = store { st in
            for i in 0..<6 { _ = st.apply(ev("UserPromptSubmit", sid: "s\(i)") { $0.prompt = "go" }) }
        }
        let quota = QuotaState(fiveHour: QuotaWindow(usedPercent: 82), sevenDay: QuotaWindow(usedPercent: 12))
        let st = NotchActivityState.make(sessions: s.active, quota: quota)
        #expect(st.rows.count == NotchActivityState.maxRows && st.more == 3)
        #expect(st.fiveHour == 0.82 && st.weekly == 0.12)
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
