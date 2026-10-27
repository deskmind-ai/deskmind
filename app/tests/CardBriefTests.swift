// The short action card (Shared/CardBrief.swift): its two lines by the executor's kinds and order, what moves under
// 「细节」, and the one line about earlier steps that may already have gone out -- never folded (#129 Codex rule).
// Run from DecisionTests.main (build.sh).

import Foundation

enum CardBriefTests {
    static func check(_ ok: Bool, _ what: String, file: StaticString = #file, line: UInt = #line) {
        DecisionTests.check(ok, "card brief: " + what, file: file, line: line)
    }

    static func brief(_ consent: [String: Any], lang: ResolvedLang = .zhHans) -> CardBrief? {
        CardBrief(CardLayout(CardLayoutTests.consentCard(consent)), lang: lang)
    }

    static func run() {
        DecisionTests.group("cardBrief")
        let out: [[String: Any]] = [["kind": "field", "label": "To", "value": "A <a@example.com>"],
                                    ["kind": "field", "label": "Subject", "value": "Re: notes"],
                                    ["kind": "typed", "label": "", "value": "on it"],
                                    ["kind": "text", "label": "", "value": "earlier message"]]
        let base: [String: Any] = ["action": "click", "action_text": "点「发送」", "target": "发送", "object": "window:x#1",
                                   "object_label": "x", "consequence": "external", "site": "mail.example.com", "outgoing": out]
        guard let b = brief(base) else { check(false, "an action card has a brief"); return }
        check(b.question == "要点「发送」吗？", "the question is the headline")
        check(b.lead == "on it" && b.leadTo == .init(label: "To", value: "A <a@example.com>"), "the typed value leads, the first field after its arrow")
        check(b.leadLine == "「on it」 → A <a@example.com>", "the first line: \(b.leadLine ?? "nil")")
        check(b.context == [.init(label: "Subject", value: "Re: notes"), .init(label: "网站", value: "mail.example.com")], "the second line: the next field and the site")
        check(b.warning == nil, "nothing uncertain: no warning")
        check(b.folded, "the window's text, where it acts and its effect are under 细节")

        // (by kinds and order, never by what a label says: the same labels in another order lay out by order)
        var swapped = base
        swapped["outgoing"] = [out[1], out[0], out[2]]
        check(brief(swapped)?.leadTo?.label == "Subject", "the first field after the arrow, whatever its label")

        // a third field and a picked item: past the two lines, under 细节 -- never dropped
        var more = base
        more["outgoing"] = out + [["kind": "field", "label": "Cc", "value": "b@example.com"]]
        check(brief(more)?.context.first?.label == "Subject" && brief(more)?.folded == true, "a third field folds")

        // no lead: no first line, the fields go to 细节
        var none = base
        none["outgoing"] = [] as [[String: Any]]
        check(brief(none)?.lead == nil && brief(none)?.leadLine == nil, "nothing to send: no first line")

        // an uncertain earlier step: one line, always shown, with how many in all
        var unsure = base
        unsure["uncertain"] = [["consequence": "external", "object": "window:x#1", "text": "点「发送」", "outgoing": [] as [[String: Any]]]]
        unsure["uncertain_total"] = 3
        let u = brief(unsure)
        check(u?.warning == "之前有 3 步可能已经发出：点「发送」", "the warning line: \(u?.warning ?? "nil")")
        check(brief(unsure, lang: .en)?.warning == "3 earlier steps may already have gone out: 点「发送」", "in English")
        var unsureBare = base
        unsureBare["uncertain_total"] = 2
        check(brief(unsureBare)?.warning == "之前有 2 步可能已经发出", "only a count: still said")

        // a card with no consent fields is drawn as it was
        let plain = CardLayoutTests.model(["kind": "action", "text": "t", "headline": "h", "free_text": false, "blocking": true,
                                           "options": [CardLayoutTests.opt("approve", "可以")]])
        check(CardBrief(CardLayout(plain), lang: .zhHans) == nil, "no consent: no brief")
    }
}
