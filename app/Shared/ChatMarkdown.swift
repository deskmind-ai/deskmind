// An assistant reply's Markdown, as the chat draws it (owner, rc.20): paragraphs, headings, lists (bulleted and
// numbered, nested by indent), fenced code and rules as blocks; bold, italics, inline code and links inside a block
// (Foundation's inline Markdown). Lines inside a paragraph keep their breaks, as the model wrote them. A reply still
// streaming parses the same way: an unclosed fence is code to the end. Nothing here draws (MessageRow does).

import Foundation

enum ChatMarkdown {
    enum Block: Equatable {
        case paragraph(String)
        case heading(String)
        case list([Item])
        case code(String)
        case rule
    }

    /// A list item: its marker (「•」 or 「3.」), its words, and how deep it is (0: the outermost).
    struct Item: Equatable {
        var marker: String
        var text: String
        var level: Int
    }

    static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
        var para: [String] = []
        var items: [Item] = []
        var code: [String]? = nil

        func flushPara() { if !para.isEmpty { out.append(.paragraph(para.joined(separator: "\n"))); para = [] } }
        func flushList() { if !items.isEmpty { out.append(.list(items)); items = [] } }

        for raw in text.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if code != nil {
                if trimmed.hasPrefix("```") { out.append(.code(code!.joined(separator: "\n"))); code = nil } else { code!.append(line) }
                continue
            }
            if trimmed.hasPrefix("```") { flushPara(); flushList(); code = []; continue }
            if trimmed.isEmpty { flushPara(); flushList(); continue }
            if ["---", "***", "___"].contains(trimmed.replacingOccurrences(of: " ", with: "")) && trimmed.count >= 3 {
                flushPara(); flushList(); out.append(.rule); continue
            }
            if let h = heading(trimmed) { flushPara(); flushList(); out.append(.heading(h)); continue }
            if let item = item(line) { flushPara(); items.append(item); continue }
            // (a line under a list item, indented: more of that item; any other line: a paragraph's)
            if !items.isEmpty, line.first == " " || line.first == "\t" {
                items[items.count - 1].text += "\n" + trimmed
                continue
            }
            flushList()
            para.append(trimmed)
        }
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }
        flushPara(); flushList()
        return out
    }

    /// 「# 标题」 to 「###### 标题」: its words.
    static func heading(_ s: String) -> String? {
        let hashes = s.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = s.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    /// 「- 」 「* 」 「+ 」 or 「12. 」 「12) 」 at the line's start, after its indent (two spaces or a tab a level).
    static func item(_ line: String) -> Item? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let level = indent.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2
        let s = line.dropFirst(indent.count)
        if let f = s.first, "-*+".contains(f), s.dropFirst().first == " " {
            return Item(marker: "•", text: s.dropFirst(2).trimmingCharacters(in: .whitespaces), level: level)
        }
        let digits = s.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let after = s.dropFirst(digits.count)
        guard let p = after.first, p == "." || p == ")", after.dropFirst().first == " " else { return nil }
        return Item(marker: digits + ".", text: after.dropFirst(2).trimmingCharacters(in: .whitespaces), level: level)
    }

    /// A block's words with their inline Markdown read (bold, italics, `code`, links); words that don't parse, as written.
    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    /// The reply as plain words (VoiceOver): the marks gone, the list markers kept.
    static func plain(_ text: String) -> String {
        blocks(text).map { b -> String in
            switch b {
            case .paragraph(let s), .heading(let s): return String(inline(s).characters)
            case .list(let items): return items.map { $0.marker + " " + String(inline($0.text).characters) }.joined(separator: "\n")
            case .code(let s): return s
            case .rule: return ""
            }
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
