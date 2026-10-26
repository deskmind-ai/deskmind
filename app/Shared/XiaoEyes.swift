// 小方's eyes for a session's state (handoff §1.5, the CardStates board): looking at its work while it works, up at
// you while a card waits, ^ ^ when done, – – when it stopped, went wrong or waits on something it can't change. The one
// map every place that draws 小方 reads (Main/Brand.swift's XiaoFace: the right column, the float, the island, the
// first run). Pure, tested in tests/RightColumnTests.swift.

import Foundation

enum XiaoEyes: Equatable, CaseIterable {
    case look, up, happy, flat

    static func of(_ s: SessionStatus) -> XiaoEyes {
        switch s {
        case .waitingForYou, .cardExpired: return .up
        case .done(_, let stopped): return stopped ? .flat : .happy
        case .error, .locked, .stopping: return .flat
        case .acting, .thinking, .paused, .lookOnly, .idle: return .look
        }
    }
}
