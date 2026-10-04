// What a run did, replayed from its step screenshots, and the same as a GIF to share. No recording is needed (a
// recording makes every step about a fifth slower, see ScreenRecorder): every step already keeps the screenshot the
// agent looked at.

import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// A step as replayed: its screenshot and what it did, in words.
struct ReplayFrame: Identifiable {
    let id = UUID()
    let n: Int
    let image: String
    let words: String
}

enum Replay {
    /// The frames of a run: the steps that kept a screenshot that is still on disk ("Clear all" deletes them).
    static func frames(_ steps: [RunStep]) -> [ReplayFrame] {
        steps.filter { !$0.shot.isEmpty && FileManager.default.fileExists(atPath: $0.shot) }
            .map { ReplayFrame(n: $0.n, image: $0.shot, words: $0.human) }
    }

    /// The run as a GIF in Movies › DeskMind: up to 16 steps (the last ones when there are more), 720 px wide, each
    /// with its step and words in a band at the bottom; the first frame names the task. Returns the file, or nil.
    @MainActor
    static func exportGIF(title: String, frames all: [ReplayFrame], lang: ResolvedLang) -> URL? {
        let frames = Array(all.suffix(16))
        guard !frames.isEmpty else { return nil }
        let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("DeskMind", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        let name = String(title.replacingOccurrences(of: "/", with: " ").replacingOccurrences(of: ":", with: " ").prefix(40))
        let url = dir.appendingPathComponent("\(stamp) \(name).gif")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count + 1, nil) else { return nil }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let width: CGFloat = 720
        var size = CGSize(width: width, height: 450)
        if let first = NSImage(contentsOfFile: frames[0].image), first.size.width > 0 {
            size.height = (width * first.size.height / first.size.width).rounded() + 48
        }
        if let cover = render(size: size, image: nil, band: title, sub: L("DeskMind · %d steps", frames.count, lang: lang)) {
            CGImageDestinationAddImage(dest, cover, delay(1.6))
        }
        for (i, f) in frames.enumerated() {
            guard let img = NSImage(contentsOfFile: f.image),
                  let frame = render(size: size, image: img, band: "\(f.n)  \(f.words)", sub: nil) else { continue }
            CGImageDestinationAddImage(dest, frame, delay(i == frames.count - 1 ? 2.6 : 1.3))
        }
        return CGImageDestinationFinalize(dest) ? url : nil
    }

    private static func delay(_ s: Double) -> CFDictionary {
        [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: s]] as CFDictionary
    }

    /// One frame: the screenshot fitted above a 48 px ink band with the words (or, for the cover, paper with the
    /// task's name).
    @MainActor
    private static func render(size: CGSize, image: NSImage?, band: String, sub: String?) -> CGImage? {
        let out = NSImage(size: size)
        out.lockFocus()
        let paper = NSColor(srgbRed: 0xF4 / 255.0, green: 0xF1 / 255.0, blue: 0xEA / 255.0, alpha: 1)
        let ink = NSColor(srgbRed: 0x26 / 255.0, green: 0x2B / 255.0, blue: 0x28 / 255.0, alpha: 1)
        let orange = NSColor(srgbRed: 0xC9 / 255.0, green: 0x55 / 255.0, blue: 0x36 / 255.0, alpha: 1)
        if let image {
            paper.setFill(); NSRect(origin: .zero, size: size).fill()
            let area = NSRect(x: 0, y: 48, width: size.width, height: size.height - 48)
            let k = min(area.width / image.size.width, area.height / image.size.height)
            let w = image.size.width * k, h = image.size.height * k
            image.draw(in: NSRect(x: (area.width - w) / 2, y: 48 + (area.height - h) / 2, width: w, height: h))
            ink.setFill(); NSRect(x: 0, y: 0, width: size.width, height: 48).fill()
            orange.setFill(); NSBezierPath(ovalIn: NSRect(x: 16, y: 19, width: 10, height: 10)).fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 17, weight: .medium), .foregroundColor: paper]
            (band as NSString).draw(with: NSRect(x: 36, y: 14, width: size.width - 52, height: 22),
                                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        } else {
            paper.setFill(); NSRect(origin: .zero, size: size).fill()
            orange.setFill(); NSBezierPath(ovalIn: NSRect(x: 48, y: size.height / 2 + 34, width: 16, height: 16)).fill()
            let big: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 30, weight: .bold), .foregroundColor: ink]
            (band as NSString).draw(with: NSRect(x: 48, y: size.height / 2 - 40, width: size.width - 96, height: 70),
                                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: big)
            if let sub {
                let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor(srgbRed: 0x5E / 255.0, green: 0x67 / 255.0, blue: 0x5F / 255.0, alpha: 1)]
                (sub as NSString).draw(at: NSPoint(x: 48, y: size.height / 2 - 72), withAttributes: small)
            }
        }
        out.unlockFocus()
        return out.cgImage(forProposedRect: nil, context: nil, hints: nil)
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
