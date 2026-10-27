// An assistant reply's Markdown read into the chat's blocks (Shared/ChatMarkdown.swift), and the three columns' widths
// at the least window (ColumnWidths, Shared/WindowFit.swift). Run from DecisionTests.main (build.sh).

import Foundation

enum ChatMarkdownTests {
    static func check(_ ok: Bool, _ what: String, file: StaticString = #file, line: UInt = #line) {
        DecisionTests.check(ok, "chat markdown: " + what, file: file, line: line)
    }

    static func run() {
        DecisionTests.group("chatMarkdown")
        typealias M = ChatMarkdown
        // (the owner's reply, rc.20: bold heads, dash lists, paragraphs)
        let reply = "**信息处理**\n- 读一份/一批文件，提炼要点\n- 把散在各处的信息汇总\n\n不擅长的：需要你本人身份验证的登录。\n第二行。"
        let b = M.blocks(reply)
        check(b == [.paragraph("**信息处理**"), .list([M.Item(marker: "•", text: "读一份/一批文件，提炼要点", level: 0), M.Item(marker: "•", text: "把散在各处的信息汇总", level: 0)]),
                    .paragraph("不擅长的：需要你本人身份验证的登录。\n第二行。")], "blocks: \(b)")
        check(String(M.inline("**信息处理**").characters) == "信息处理", "bold's marks gone")
        check(M.inline("**信息处理**").runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }, "bold read as bold")
        check(M.inline("用 `ls -la` 看").runs.contains { $0.inlinePresentationIntent?.contains(.code) == true }, "inline code read as code")
        check(M.plain(reply).hasPrefix("信息处理\n• 读一份") && !M.plain(reply).contains("**"), "VoiceOver's words: \(M.plain(reply))")
        // numbered, nested, continued, headings, code (closed and still streaming), rules
        check(M.blocks("1. 一\n2) 二\n  - 子项\n    接着说") == [.list([M.Item(marker: "1.", text: "一", level: 0), M.Item(marker: "2.", text: "二", level: 0),
                                                        M.Item(marker: "•", text: "子项\n接着说", level: 1)])], "numbered, nested, continued")
        check(M.blocks("## 能做的\n正文") == [.heading("能做的"), .paragraph("正文")], "a heading")
        check(M.blocks("#没有空格") == [.paragraph("#没有空格")] && M.blocks("2026年 10 月") == [.paragraph("2026年 10 月")], "not headings or items")
        check(M.blocks("看：\n```sh\nls -la\n```\n好") == [.paragraph("看："), .code("ls -la"), .paragraph("好")], "fenced code")
        check(M.blocks("```\nlet a = 1") == [.code("let a = 1")], "a fence still streaming: code to the end")
        check(M.blocks("上\n\n---\n\n下") == [.paragraph("上"), .rule, .paragraph("下")], "a rule")
        check(M.blocks("*斜体* 不是列表") == [.paragraph("*斜体* 不是列表")], "a star with no space is no item")

        DecisionTests.group("columnWidths")
        typealias C = ColumnWidths
        check(C.windowMin == 1098, "the least window stays 1098: \(C.windowMin)")
        check(C.right(in: 1098) == 300 && 1098 - 256 - 2 - C.right(in: 1098) == 540, "at 1098: the right column 300, the chat 540")
        check(C.right(in: 1148) == 350 && C.right(in: 1198) == 400 && C.right(in: 1440) == 400, "the right column grows back to 400 first")
        check(C.right(in: 900) == 300, "never under 300")
    }
}
