import SwiftUI

/// Parses SVG path data (`d` attribute) into a SwiftUI `Path`.
/// Supports every command Simple Icons uses: M L H V C S Q T A Z, absolute and relative.
enum SVGPath {
    static func parse(_ d: String) -> Path {
        var path = Path()
        var s = Tokenizer(Array(d.utf8))
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint?      // for S / T reflection
        var lastCommand: UInt8 = 0

        while let cmd = s.nextCommand(implicitAfter: lastCommand) {
            let rel = cmd >= 97 // lowercase
            let upper = rel ? cmd - 32 : cmd
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                rel ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }

            switch upper {
            case UInt8(ascii: "M"):
                guard let x = s.number(), let y = s.number() else { return path }
                current = pt(x, y); start = current
                path.move(to: current)
                lastControl = nil
                // Extra coordinate pairs after M are implicit L.
                lastCommand = rel ? UInt8(ascii: "l") : UInt8(ascii: "L")
                continue
            case UInt8(ascii: "L"):
                guard let x = s.number(), let y = s.number() else { return path }
                current = pt(x, y); path.addLine(to: current); lastControl = nil
            case UInt8(ascii: "H"):
                guard let x = s.number() else { return path }
                current = CGPoint(x: rel ? current.x + x : x, y: current.y)
                path.addLine(to: current); lastControl = nil
            case UInt8(ascii: "V"):
                guard let y = s.number() else { return path }
                current = CGPoint(x: current.x, y: rel ? current.y + y : y)
                path.addLine(to: current); lastControl = nil
            case UInt8(ascii: "C"):
                guard let x1 = s.number(), let y1 = s.number(), let x2 = s.number(), let y2 = s.number(),
                      let x = s.number(), let y = s.number() else { return path }
                let c1 = pt(x1, y1), c2 = pt(x2, y2), end = pt(x, y)
                path.addCurve(to: end, control1: c1, control2: c2)
                lastControl = c2; current = end
            case UInt8(ascii: "S"):
                guard let x2 = s.number(), let y2 = s.number(), let x = s.number(), let y = s.number() else { return path }
                let c1 = reflect(lastControl, previous: lastCommand, kinds: "CcSs", around: current)
                let c2 = pt(x2, y2), end = pt(x, y)
                path.addCurve(to: end, control1: c1, control2: c2)
                lastControl = c2; current = end
            case UInt8(ascii: "Q"):
                guard let x1 = s.number(), let y1 = s.number(), let x = s.number(), let y = s.number() else { return path }
                let c = pt(x1, y1), end = pt(x, y)
                path.addQuadCurve(to: end, control: c)
                lastControl = c; current = end
            case UInt8(ascii: "T"):
                guard let x = s.number(), let y = s.number() else { return path }
                let c = reflect(lastControl, previous: lastCommand, kinds: "QqTt", around: current)
                let end = pt(x, y)
                path.addQuadCurve(to: end, control: c)
                lastControl = c; current = end
            case UInt8(ascii: "A"):
                guard let rx = s.number(), let ry = s.number(), let rot = s.number(),
                      let large = s.flag(), let sweep = s.flag(),
                      let x = s.number(), let y = s.number() else { return path }
                let end = pt(x, y)
                addArc(to: &path, from: current, to: end, rx: rx, ry: ry,
                       rotation: rot, largeArc: large, sweep: sweep)
                current = end; lastControl = nil
            case UInt8(ascii: "Z"):
                path.closeSubpath()
                current = start; lastControl = nil
            default:
                return path
            }
            lastCommand = cmd
        }
        return path
    }

    private static func reflect(_ control: CGPoint?, previous: UInt8, kinds: String,
                                around p: CGPoint) -> CGPoint {
        guard let c = control, kinds.utf8.contains(previous) else { return p }
        return CGPoint(x: 2 * p.x - c.x, y: 2 * p.y - c.y)
    }

    /// Endpoint-parameterized arc (SVG spec F.6) converted to cubic Béziers.
    private static func addArc(to path: inout Path, from p0: CGPoint, to p1: CGPoint,
                               rx rxIn: CGFloat, ry ryIn: CGFloat, rotation: CGFloat,
                               largeArc: Bool, sweep: Bool) {
        var rx = abs(rxIn), ry = abs(ryIn)
        if rx == 0 || ry == 0 || p0 == p1 { path.addLine(to: p1); return }

        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy

        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }

        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coef = sqrt(max(0, num / den))
        if largeArc == sweep { coef = -coef }
        let cxp = coef * rx * y1p / ry
        let cyp = -coef * ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        let t = 4.0 / 3.0 * tan(step / 4)

        func point(_ theta: CGFloat) -> CGPoint {
            let x = rx * cos(theta), y = ry * sin(theta)
            return CGPoint(x: cx + cosPhi * x - sinPhi * y, y: cy + sinPhi * x + cosPhi * y)
        }
        func derivative(_ theta: CGFloat) -> CGPoint {
            let x = -rx * sin(theta), y = ry * cos(theta)
            return CGPoint(x: cosPhi * x - sinPhi * y, y: sinPhi * x + cosPhi * y)
        }

        var theta = theta1
        for i in 0..<segments {
            let next = theta + step
            let a = point(theta), b = point(next)
            let da = derivative(theta), db = derivative(next)
            let c1 = CGPoint(x: a.x + t * da.x, y: a.y + t * da.y)
            let c2 = CGPoint(x: b.x - t * db.x, y: b.y - t * db.y)
            path.addCurve(to: i == segments - 1 ? p1 : b, control1: c1, control2: c2)
            theta = next
        }
    }

    private struct Tokenizer {
        let bytes: [UInt8]
        var i = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func skipSeparators() {
            while i < bytes.count, bytes[i] == 32 || bytes[i] == 44 || bytes[i] == 9 || bytes[i] == 10 || bytes[i] == 13 {
                i += 1
            }
        }

        /// Returns the next explicit command letter, or repeats the previous one when a number follows.
        mutating func nextCommand(implicitAfter last: UInt8) -> UInt8? {
            skipSeparators()
            guard i < bytes.count else { return nil }
            let c = bytes[i]
            if (c >= 65 && c <= 90) || (c >= 97 && c <= 122) {
                if c == UInt8(ascii: "e") || c == UInt8(ascii: "E") { return nil }
                i += 1
                return c
            }
            return last == 0 ? nil : last
        }

        mutating func flag() -> Bool? {
            skipSeparators()
            guard i < bytes.count else { return nil }
            let c = bytes[i]
            guard c == UInt8(ascii: "0") || c == UInt8(ascii: "1") else { return nil }
            i += 1
            return c == UInt8(ascii: "1")
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            let startIndex = i
            if i < bytes.count, bytes[i] == UInt8(ascii: "-") || bytes[i] == UInt8(ascii: "+") { i += 1 }
            var sawDot = false, sawDigit = false
            while i < bytes.count {
                let c = bytes[i]
                if c >= 48 && c <= 57 { sawDigit = true; i += 1 }
                else if c == UInt8(ascii: "."), !sawDot { sawDot = true; i += 1 }
                else { break }
            }
            if sawDigit, i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
                i += 1
                if i < bytes.count, bytes[i] == UInt8(ascii: "-") || bytes[i] == UInt8(ascii: "+") { i += 1 }
                while i < bytes.count, bytes[i] >= 48 && bytes[i] <= 57 { i += 1 }
            }
            guard sawDigit, let str = String(bytes: bytes[startIndex..<i], encoding: .ascii),
                  let v = Double(str) else { i = startIndex; return nil }
            return CGFloat(v)
        }
    }
}

/// A brand mark from Simple Icons, drawn in the 24×24 grid and scaled to fit.
struct BrandShape: Shape {
    let path: Path

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let dx = rect.minX + (rect.width - 24 * scale) / 2
        let dy = rect.minY + (rect.height - 24 * scale) / 2
        return path.applying(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: dx, ty: dy))
    }

    private static var cache: [String: Path] = [:]

    static func named(_ slug: String) -> BrandShape? {
        if let p = cache[slug] { return BrandShape(path: p) }
        guard let d = BrandPaths.all[slug] else { return nil }
        let p = SVGPath.parse(d)
        cache[slug] = p
        return BrandShape(path: p)
    }
}
