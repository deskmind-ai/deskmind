// The few SVG path commands the brand mark uses (M, H, V, Q, Z, absolute), as a CGPath: 小方 is drawn from
// brand/xiaofang/*.svg (Main/Listening.swift). CoreGraphics only, so tests/DecisionTests.swift checks it.

import CoreGraphics
import Foundation

enum MarkPath {
    static func cgPath(_ d: String) -> CGPath {
        let p = CGMutablePath()
        let scanner = Scanner(string: d)
        scanner.charactersToBeSkipped = CharacterSet(charactersIn: " ,")
        var cur = CGPoint.zero
        func num() -> CGFloat { CGFloat(scanner.scanDouble() ?? 0) }
        while !scanner.isAtEnd {
            guard let c = scanner.scanCharacter() else { break }
            switch c {
            case "M": cur = CGPoint(x: num(), y: num()); p.move(to: cur)
            case "H": cur = CGPoint(x: num(), y: cur.y); p.addLine(to: cur)
            case "V": cur = CGPoint(x: cur.x, y: num()); p.addLine(to: cur)
            case "Q": let c1 = CGPoint(x: num(), y: num()); cur = CGPoint(x: num(), y: num()); p.addQuadCurve(to: cur, control: c1)
            case "Z": p.closeSubpath()
            default: break
            }
        }
        return p
    }
}
