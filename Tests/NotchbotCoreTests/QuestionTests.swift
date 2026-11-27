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
}
