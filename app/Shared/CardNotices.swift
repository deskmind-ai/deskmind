// A chat task's notifications (A7, plan §1.4, invariant 4): what CardPlacement says of the open card -- post it, post it
// once more at 20 s, leave it, take it away -- carried out, with each notification named after what it is about
// ("ask:<ask_id>", "run:<run_id>"), so it can be taken away again: when the card is answered, voided or expired, when
// the float or the window shows it, and at launch for any left by an app that went away. A notification carries no
// answer: clicking it opens DeskMind (the app's reopen: a user gesture) on the card; it is never a second way to answer.
// "Reminded once" is a fact kept here, not read back from the notification center, so a window flipping back and forth
// never reminds twice.

import Foundation

/// What posts and takes away notifications (the app: UNUserNotificationCenter; a test: its own).
protocol CardNotifier: AnyObject {
    func post(id: String, title: String, body: String)
    func remove(ids: [String])
    /// The ids of the notifications on screen now (for the launch's clean-up).
    func delivered(_ done: @escaping ([String]) -> Void)
}

final class CardNotices {
    private let notifier: CardNotifier
    /// The open card's notification, as far as it went: how many were posted, when the last was -- kept for the card's
    /// life (a card is posted at most once and reminded at most once, however often the window flips), and which are on
    /// screen now.
    private var notified: [String: (count: Int, at: Double)] = [:]
    private var onScreen: Set<String> = []
    /// Runs whose end was notified (taken away once the window shows the task).
    private var endedRuns: Set<String> = []

    init(_ notifier: CardNotifier) { self.notifier = notifier }

    static func askId(_ ask: String) -> String { "ask:" + ask }
    static func runId(_ run: String) -> String { "run:" + run }

    /// The waiting card `askId` (nil: none waits now) placed `placement` at `now`: what the notification does.
    func card(_ askId: String?, placement: CardPlacement?, title: String, body: String, now: Double) {
        // every other card's notification goes: it is answered, voided, expired or replaced
        for id in notified.keys where id != askId.map(Self.askId) {
            if onScreen.remove(id) != nil { notifier.remove(ids: [id]) }
            notified[id] = nil
        }
        guard let ask = askId, let p = placement else { return }
        let id = Self.askId(ask)
        switch p.notification {
        case .post where notified[id] == nil:
            notifier.post(id: id, title: title, body: body); notified[id] = (1, now); onScreen.insert(id)
        case .remind where notified[id]?.count == 1:
            notifier.post(id: id, title: title, body: body); notified[id] = (2, now); onScreen.insert(id)
        case .withdrawn:
            // (seen in the float or the window: taken away -- and not posted again for this card)
            if onScreen.remove(id) != nil { notifier.remove(ids: [id]) }
        default: break
        }
    }

    /// What placement is given of the card's notifications so far (CardPlacement.place's `notified`).
    func notified(_ askId: String, now: Double) -> (count: Int, since: Double)? {
        notified[Self.askId(askId)].map { ($0.count, now - $0.at) }
    }

    /// A task ended while DeskMind was not looked at: said once; taken away when the window shows it.
    func ended(_ run: String, title: String, body: String, seen: Bool) {
        let id = Self.runId(run)
        if seen { if endedRuns.remove(run) != nil { notifier.remove(ids: [id]) }; return }
        guard !endedRuns.contains(run) else { return }
        endedRuns.insert(run)
        notifier.post(id: id, title: title, body: body)
    }

    /// At launch: any card notification left by an app that went away whose card no longer waits goes.
    func cleanUp(waiting: Set<String>) {
        notifier.delivered { [notifier] ids in
            let stale = ids.filter { $0.hasPrefix("ask:") && !waiting.contains(String($0.dropFirst(4))) }
            if !stale.isEmpty { notifier.remove(ids: stale) }
        }
    }
}
