// An action card as short as the boards draw it (owner, #133): P1Waiting's two lines -- 「「我看一下再说」 → 许诺」 and
// 「主题 … · 网站 …」 -- and P1Float's question with what goes out. Everything else the card carries (the other fields,
// what is picked, the window's other text, where it acts, the model's words) moves under 「细节」; nothing is dropped
// (`folded` says there is more). Built from CardLayout's consent by the executor's kinds and order only, never by
// what a label says (U3 §2.2): the lead line is the block's, the line after its arrow the first other field, the second
// line the next field and the site.
//
// The #129 Codex rule is kept: an earlier step whose result is unknown -- it may already have gone out -- is never
// folded. It is one short line, always shown, on the card and in the float alike.

import Foundation

struct CardBrief: Equatable {
    struct Pair: Equatable { var label: String; var value: String }
    /// The card's question: its headline (the harness's own sentence), else its text.
    var question: String
    /// What goes out, in one line: the lead value (quoted where drawn) and, after its arrow, the first other field's
    /// value. nil: the block has no lead.
    var lead: String?
    var leadTo: Pair?
    /// The second line: the next field and the site.
    var context: [Pair]
    /// One short line, always shown: earlier steps that may already have gone out.
    var warning: String?
    /// The card has more than the brief shows (under 「细节」 in the window; the float's 「去主窗口回答」).
    var folded: Bool

    /// nil for a card with no consent fields (it is drawn as it was).
    init?(_ layout: CardLayout, lang: ResolvedLang) {
        guard let c = layout.consent else { return nil }
        question = layout.title
        let b = c.block
        lead = b.lead?.value
        var rest = b.fields + b.other
        leadTo = lead == nil || rest.isEmpty ? nil : { let o = rest.removeFirst(); return Pair(label: o.label, value: o.value) }()
        context = []
        if !rest.isEmpty { let o = rest.removeFirst(); context.append(Pair(label: o.label, value: o.value)) }
        if let s = c.site, !s.isEmpty { context.append(Pair(label: L("Site", lang: lang), value: s)) }
        let n = c.uncertain.count + c.uncertainMore
        if n > 0 {
            let first = c.uncertain.first?.text ?? ""
            warning = first.isEmpty ? L("%d earlier steps may already have gone out", n, lang: lang)
                                    : L("%d earlier steps may already have gone out: %@", n, first, lang: lang)
        }
        // (the lead's own label, a field past the two lines, picks, the window's text, where it acts, the effect, the
        // model's words, a field the app cannot show, the text not all said by the drawn words: 「细节」)
        folded = b.leadLabel != nil || !rest.isEmpty || !b.selected.isEmpty || !b.text.isEmpty || !c.selected.isEmpty
            || !c.object.isEmpty || c.effect != nil || c.modelSays != nil || !c.uncertain.isEmpty || c.actionRow || layout.hasDetails
    }

    /// The first line as drawn: 「「X」 → Y」 (no arrow without a second value).
    var leadLine: String? {
        guard let l = lead else { return nil }
        return "「" + l + "」" + (leadTo.map { " → " + $0.value } ?? "")
    }
}
