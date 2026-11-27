import Foundation
import Testing

@testable import NotchbotCore

@Suite struct QuestionTests {
    func input(_ json: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) }

    @Test func parsesTheQuestionAndItsChoices() throws {
        let q = try #require(
            AskedQuestion.parse(
                try input(
                    #"{"questions":[{"question":"Which database should we use?","header":"Database","multiSelect":false,"options":[{"label":"Postgres","description":"relational"},{"label":"SQLite"}]},{"question":"Second?","options":[]}]}"#
                )))
        #expect(q.text == "Which database should we use?" && q.header == "Database")
        #expect(q.options == ["Postgres", "SQLite"] && !q.multiSelect && q.total == 2)
    }

    @Test func toleratesOddShapes() throws {
        #expect(AskedQuestion.parse(nil) == nil)
        #expect(AskedQuestion.parse(try input(#"{"questions":[]}"#)) == nil)
        #expect(AskedQuestion.parse(try input(#"{"questions":[{"question":""}]}"#)) == nil)
        let plain = try #require(
            AskedQuestion.parse(try input(#"{"questions":[{"question":"Pick","options":["A","B"],"multiSelect":true}]}"#)))
        #expect(plain.options == ["A", "B"] && plain.multiSelect)  // bare-string options
    }

    @Test func aPermissionRequestForTheQuestionToolIsShownAsAQuestion() throws {
        var s = SessionStore()
        let q = try input(#"{"questions":[{"question":"Ship it now?","options":[{"label":"Yes"},{"label":"Not yet"}]}]}"#)
        s.apply(
            ev("PermissionRequest", expectsReply: true) {
                $0.toolName = "AskUserQuestion"; $0.toolInput = q
            })
        let p = try #require(s.sessions["s1"]?.pending)
        #expect(p.isQuestion && p.summary == "Ship it now?")  // not "AskUserQuestion: ..."
        #expect(p.question?.options == ["Yes", "Not yet"])
        // An ordinary tool is not a question.
        var t = SessionStore()
        t.apply(
            ev("PermissionRequest", expectsReply: true) {
                $0.toolName = "Bash"; $0.toolInput = .object(["command": .string("ls")])
            })
        #expect(t.sessions["s1"]?.pending?.isQuestion == false)
    }

    // MARK: answering in the island

    private func asking(_ json: String, canAnswer: Bool = true) throws -> AgentSession {
        var t = SessionStore()
        t.apply(
            ev("PermissionRequest", expectsReply: canAnswer) {
                $0.toolName = "AskUserQuestion"; $0.toolInput = try! input(json)
            })
        return try #require(t.sessions["s1"])
    }

    static let db =
        #"{"questions":[{"question":"Which database?","header":"Database","multiSelect":false,"options":[{"label":"Postgres","description":"Relational"},{"label":"SQLite"},{"label":"DynamoDB","description":"Managed NoSQL"}]}]}"#

    @Test func onlyASingleSelectQuestionIsAnsweredInline() throws {
        #expect(try asking(Self.db).pending?.question?.canAnswerInline == true)
        let multi = Self.db.replacingOccurrences(of: #""multiSelect":false"#, with: #""multiSelect":true"#)
        #expect(try asking(multi).pending?.question?.canAnswerInline == false)
        let two = #"{"questions":[{"question":"A?","options":[{"label":"x"}]},{"question":"B?","options":[{"label":"y"}]}]}"#
        #expect(try asking(two).pending?.question?.canAnswerInline == false)
        #expect(try asking(#"{"questions":[{"question":"Free text?"}]}"#).pending?.question?.canAnswerInline == false)
    }

    @Test func descriptionsStayParallelToTheChoices() throws {
        let q = try #require(AskedQuestion.parse(try input(Self.db)))
        #expect(q.options == ["Postgres", "SQLite", "DynamoDB"] && q.descriptions == ["Relational", "", "Managed NoSQL"])
    }

    @Test func theCardCarriesTheChoicesAndTakesTheIsland() throws {
        let s = try asking(Self.db)
        var other = s; other.id = "s2"
        let st = NotchActivityState.make(sessions: [s, other], quota: nil)
        let p = try #require(st.prompt)
        #expect(p.canChoose && p.requestId == s.pending?.id.uuidString)
        #expect(p.choices.map(\.label) == ["Postgres", "SQLite", "DynamoDB"])
        #expect(p.choices.map(\.detail) == ["Relational", "", "Managed NoSQL"])
        // A tall card: no session rows under it, and the others sit on the next page; the header counts everyone.
        #expect(st.rows.isEmpty && st.pages == 2 && st.more == 1 && st.needsYou == 2)
        #expect(st.encodedSize <= NotchActivityState.byteBudget)
        let next = NotchActivityState.make(sessions: [s, other], quota: nil, page: 1)
        #expect(next.prompt == nil && next.rows.map(\.id) == ["s2"])
        let back = NotchActivityState.make(sessions: [s, other], quota: nil, page: 2)  // pages wrap
        #expect(back.prompt?.canChoose == true && back.rows.isEmpty)
        // The island never turns away from the question by itself.
        #expect(!IslandGuard.canAutoTurn(state: st, promptChangedAt: .distantPast))
    }

    @Test func longChoicesAreClippedAndStayInTheBudget() throws {
        let long = String(repeating: "word ", count: 80)
        let opts = (1...6).map { #"{"label":"Option \#($0) \#(long)","description":"\#(long)"}"# }.joined(separator: ",")
        let s = try asking(#"{"questions":[{"question":"\#(long)","options":[\#(opts)]}]}"#)
        let p = try #require(NotchActivityState.make(sessions: [s], quota: nil).prompt)
        #expect(p.choices.count == NotchActivityState.maxOptions)
        #expect(p.choices.allSatisfy { $0.label.count <= 80 && $0.detail.count <= 100 })
        #expect(NotchActivityState.make(sessions: [s], quota: nil).encodedSize <= NotchActivityState.byteBudget)
    }

    @Test func choicesAreNotOfferedWhenTheIslandCannotAnswer() throws {
        let p = try #require(NotchActivityState.make(sessions: [try asking(Self.db, canAnswer: false)], quota: nil).prompt)
        #expect(!p.canChoose && p.choices.isEmpty)
        let multi = Self.db.replacingOccurrences(of: #""multiSelect":false"#, with: #""multiSelect":true"#)
        let m = try #require(NotchActivityState.make(sessions: [try asking(multi)], quota: nil).prompt)
        #expect(!m.canChoose && m.choices.isEmpty && !m.options.isEmpty)
    }

    @Test func aQuestionLetThroughToClaudeSaysSo() throws {
        var t = SessionStore()
        t.apply(ev("UserPromptSubmit") { $0.prompt = "go" })
        t.apply(
            ev("PreToolUse") {
                $0.toolName = "AskUserQuestion"; $0.toolInput = try! input(Self.db)
            })
        #expect(try #require(t.sessions["s1"]).activity == "Waiting for your answer in Claude")
    }

    @Test func theBrokerDeliversTheChosenLabelOnce() throws {
        final class Sink: ReplySink, @unchecked Sendable {
            var sent: [HookReply] = []
            func send(_ r: HookReply) { sent.append(r) }
        }
        var b = PermissionBroker(); let sink = Sink()
        b.register(sink, for: "s1")
        let first = b.answerQuestion("s1", question: "Which database?", choice: "SQLite")
        #expect(first)
        #expect(sink.sent == [HookReply(decision: .allow, answers: ["Which database?": "SQLite"])])
        let second = b.answerQuestion("s1", question: "Which database?", choice: "Postgres")
        #expect(!second)  // already answered
        #expect(sink.sent.count == 1)
    }
}
