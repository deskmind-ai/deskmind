// 小方's pictures for dark appearance (U4, fable): each light PNG's colours moved to the dark tokens (ShellPalette),
// alpha untouched -- ink #262B28 → #E7E9E4, paper #F4F1EA → #1C1F1D, the dot #C95536 → #E06B4C. A pixel between two
// of them (an anti-aliased edge where ink meets the dot) goes to the same point between their dark ones; partly
// transparent ink edges keep their alpha, so they follow by themselves. No plate, no outline.
//
//   swift app/Resources/brand/dark.swift app/Resources/brand/idle.png app/Resources/brand/idle-dark.png

import AppKit

let tokens: [(light: [Double], dark: [Double])] = [
    ([0x26, 0x2B, 0x28], [0xE7, 0xE9, 0xE4]),   // ink
    ([0xF4, 0xF1, 0xEA], [0x1C, 0x1F, 0x1D]),   // paper
    ([0xC9, 0x55, 0x36], [0xE0, 0x6B, 0x4C]),   // the dot
]

/// The pixel's colour as a point on the nearest line between two light tokens, then the same point between their dark
/// ones.
func darken(_ c: [Double]) -> [Double] {
    var best: (d: Double, out: [Double]) = (.infinity, c)
    for i in tokens.indices { for j in tokens.indices where j > i {
        let a = tokens[i].light, b = tokens[j].light
        let ab = zip(b, a).map { $0 - $1 }, ac = zip(c, a).map { $0 - $1 }
        let len = ab.reduce(0) { $0 + $1 * $1 }
        let t = max(0, min(1, zip(ab, ac).reduce(0) { $0 + $1.0 * $1.1 } / len))
        let p = zip(a, ab).map { $0 + t * $1 }
        let d = zip(p, c).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }
        if d < best.d { best = (d, zip(tokens[i].dark, tokens[j].dark).map { $0 + t * ($1 - $0) }) }
    }}
    return best.out
}

let args = CommandLine.arguments
guard args.count == 3, let src = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: args[1]))) else {
    print("usage: dark.swift <light.png> <dark.png>"); exit(2)
}
let w = src.pixelsWide, h = src.pixelsHigh
let dst = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB, bitmapFormat: .alphaNonpremultiplied, bytesPerRow: 0, bitsPerPixel: 32)!
for y in 0..<h { for x in 0..<w {
    var p = [Int](repeating: 0, count: 4)
    src.getPixel(&p, atX: x, y: y)
    let rgb = darken(p.prefix(3).map(Double.init)).map { Int($0.rounded()) }
    var q = rgb + [p[3]]
    dst.setPixel(&q, atX: x, y: y)
}}
try dst.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
