// What a run did, replayed from its step screenshots, and the same as a GIF to share. No recording is needed (a
// recording makes every step about a fifth slower, see ScreenRecorder): every step already keeps the screenshot the
// agent looked at.

import AppKit
import SwiftUI

enum Replay {
    /// The frames of a run: the steps that kept a screenshot that is still on disk ("Clear all" deletes them).
    static func frames(_ steps: [RunStep]) -> [ReplayFrame] {
        steps.filter { !$0.shot.isEmpty && FileManager.default.fileExists(atPath: $0.shot) }
            .map { ReplayFrame(n: $0.n, image: $0.shot, words: $0.human) }
    }
}

/// The replay: each step's screenshot and words, one after another (or by hand).
struct ReplayView: View {
    let title: String
    let frames: [ReplayFrame]
    let onClose: () -> Void
    @State private var i = 0
    @State private var playing = true
    @Environment(\.lang) private var lang
    private let timer = Timer.publish(every: 1.4, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(Brand.ink).lineLimit(2)
            if frames.indices.contains(i), let img = NSImage(contentsOfFile: frames[i].image) {
                Image(nsImage: img).resizable().interpolation(.high).scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 420)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                HStack(spacing: 8) {
                    Circle().fill(Brand.dot).frame(width: 8, height: 8)
                    Text("\(frames[i].n)").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(Brand.sage)
                    Text(frames[i].words).font(.system(size: 14, design: .rounded)).foregroundStyle(Brand.ink).lineLimit(2)
                }
            }
            HStack(spacing: 10) {
                Button { playing = false; i = max(0, i - 1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(InkButtonStyle(prominent: false)).accessibilityLabel(L("Previous step", lang: lang))
                Button { playing.toggle() } label: { Image(systemName: playing ? "pause.fill" : "play.fill") }
                    .buttonStyle(InkButtonStyle()).accessibilityLabel(playing ? L("Pause", lang: lang) : L("Play", lang: lang))
                Button { playing = false; i = min(frames.count - 1, i + 1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(InkButtonStyle(prominent: false)).accessibilityLabel(L("Next step", lang: lang))
                Text("\(min(i + 1, frames.count)) / \(frames.count)").font(.system(size: 12, design: .rounded)).foregroundStyle(Brand.sage)
                Spacer()
                Button(L("Done", lang: lang), action: onClose).buttonStyle(InkButtonStyle(prominent: false)).keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 640)
        .background(Brand.paper)
        .onReceive(timer) { _ in
            guard playing, !frames.isEmpty else { return }
            if i < frames.count - 1 { i += 1 } else { playing = false }
        }
    }
}
