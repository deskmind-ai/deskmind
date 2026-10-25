// A finished task's title and summary from its latest record of what happened (A8, plan §3.7, invariant 7): its end,
// then an undo of it; task_closed adds only a line. Each case's records come in every interleaving of the session's
// stream and the executor's (each in its own stored order); the words wanted are the table's, by the stored records.
import Foundation

enum TaskTitleTests {
    static func check(_ ok: Bool, _ what: String, file: StaticString = #file, line: UInt = #line) {
        DecisionTests.check(ok, "task-title: " + what, file: file, line: line)
    }

    static func run() {
        DecisionTests.group("task-title.table"); tableTests()
    }

    static func ex(_ seq: Int, _ body: String) -> ProtocolLine { SessionTests.ex(seq, body) }
    static func se(_ seq: Int, _ body: String) -> ProtocolLine { SessionTests.se(seq, body) }

    static func tableTests() {
        let start = ex(1, #""kind":"start","raw":"x""#)
        let done = ex(2, #""kind":"task_done","undo_until":2000000000,"status":"succeeded","reason":"","summary":"建了 3 个文件","result_card":{"kind":"result","text":"做了：新建 3 个文件","options":[{"kind":"approve","text":"好的"},{"kind":"undo","text":"撤回"}]}"#)
        let end = se(2, #""kind":"session.task_end","run_id":"r1","status":"succeeded","summary":"建了 3 个文件","undo":"open""#)
        let respond = se(3, #""kind":"session.task_respond","run_id":"r1","option":1,"undo":true"#)
        func undo(_ seq: Int, _ n: Int, _ m: Int, refused: String? = nil, unknown: Bool = false) -> ProtocolLine {
            var b = #""kind":"session.task_undo","run_id":"r1","undone":\#(n),"total":\#(m)"#
            if let refused { b += #","refused":"\#(refused)""# }
            if unknown { b += #","unknown":true"# }
            return se(seq, b)
        }
        func closed(_ seq: Int, _ why: String) -> ProtocolLine { se(seq, #""kind":"session.task_closed","run_id":"r1","why":"\#(why)""#) }
        // the end cut off, then recorded again on the reopen: the later end's words
        let endCut = se(2, #""kind":"session.task_end","run_id":"r1","status":"stopped","summary":"","undo":"none","cause":"last_step_unknown""#)
        let endAgain = se(4, #""kind":"session.task_end","run_id":"r1","status":"succeeded","summary":"补记：建了 1 个文件","undo":"none""#)
        let exit = se(3, #""kind":"session.exit","code":0,"last_seq":2"#)

        // (session lines, executor lines) → (title, summary), in Chinese
        let cases: [(String, [ProtocolLine], [ProtocolLine], String, String)] = [
            ("the end", [end], [start, done], "完成了", "建了 3 个文件"),
            ("all undone", [end, respond, undo(4, 3, 3)], [start, done], "已撤回", "改动都撤回了（3 处）"),
            ("all undone, then closed", [end, respond, undo(4, 3, 3), closed(5, "linger")], [start, done], "已撤回", "改动都撤回了（3 处）"),
            ("partly undone", [end, respond, undo(4, 2, 3, refused: "a.txt 改过了")], [start, done], "完成了", "建了 3 个文件"),
            ("undo refused at the first", [end, respond, undo(4, 0, 3, refused: "a.txt 改过了")], [start, done], "完成了", "建了 3 个文件"),
            ("undo too late", [end, respond, undo(4, 0, 0, refused: "expired")], [start, done], "完成了", "建了 3 个文件"),
            ("undo cut off", [end, respond, undo(4, 0, 0, refused: "cut off", unknown: true)], [start, done], "完成了", "建了 3 个文件"),
            ("closed, no undo", [end, closed(3, "new_task")], [start, done], "完成了", "建了 3 个文件"),
            ("closed before any end", [closed(2, "session_end")], [start], "中断了", ""),
            ("an end recorded again after a reopen", [endCut, exit, endAgain], [start], "完成了", "补记：建了 1 个文件"),
        ]
        struct RNG { var s: UInt64; mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s >> 33 } }
        for (name, session, executor, title, summary) in cases {
            var seen: Set<String> = []
            for seed in 1...16 {
                // an interleaving: each stream in its own order, the two merged at random
                var r = RNG(s: UInt64(seed)), a = session[...], b = executor[...], order: [ProtocolLine] = [SessionTests.taskR1]
                while !a.isEmpty || !b.isEmpty {
                    if b.isEmpty || (!a.isEmpty && r.next() % 2 == 0) { order.append(a.removeFirst()) } else { order.append(b.removeFirst()) }
                }
                let s = SessionReducer.reduce(SessionState(), order)
                guard let t = s.task("r1") else { check(false, "\(name): the task"); continue }
                let got = (ShellText.task(t, lang: .zhHans), ShellText.summary(t, lang: .zhHans))
                seen.insert("\(got.0) | \(got.1)")
                check(got.0 == title && got.1 == summary, "\(name), seed \(seed): \(got.0) / \(got.1) (want \(title) / \(summary))")
            }
            check(seen.count == 1, "\(name): the same words in every order: \(seen)")
        }
        // the result line still says what came of a partial or refused undo (its words are the end's)
        let partial = SessionReducer.reduce(SessionState(), [SessionTests.taskR1, start, done, end, respond, undo(4, 2, 3, refused: "a.txt 改过了")])
        if let t = partial.task("r1") {
            check(ShellText.resultLine(t, hint: nil, now: 0, lang: .zhHans)?.contains("a.txt 改过了") == true, "partly undone: the line says why")
        } else { check(false, "the partial case's task") }
    }
}
