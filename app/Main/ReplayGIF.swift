// A finished run as a GIF to share, from the screenshots its steps kept (Main/Replay.swift replays the same frames).
// AppKit and ImageIO only, so tests/e2e/redesign.sh exports real GIFs with it.

import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ReplayGIF {
    static let moviesDir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DeskMind", isDirectory: true)

    /// The run as a GIF in Movies › DeskMind: up to 16 steps (the last ones when there are more), 720 px wide, each
    /// with its step and words in a band at the bottom; the first frame names the task. Returns the file, or nil.
    /// Decodes and draws every frame: call it off the main thread (it draws into its own bitmaps).
    static func exportGIF(title: String, frames all: [ReplayFrame], lang: ResolvedLang, dir: URL = moviesDir) -> URL? {
        let frames = ReplayPlan.gifFrames(all)
        guard !frames.isEmpty else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        // Never over a GIF already there (the stamp is to the minute): ExportName adds " 2", " 3"…
        let url = ExportName.unique(dir: dir, stamp: stamp, title: title, ext: "gif")
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
    /// task's name). Drawn at one pixel a point -- an NSImage's lockFocus would draw at the screen's scale, a GIF twice
    /// as wide and four times the size.
    private static func render(size: CGSize, image: NSImage?, band: String, sub: String?) -> CGImage? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
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
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }
}
