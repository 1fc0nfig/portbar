import AppKit
import SwiftUI

/// Turns terminal output into styled text. Keeps style state across lines, like a terminal does.
/// Lines without any color get a fallback: errors red, warnings orange. URLs are always links.
struct ANSIParser {
    private struct Style: Equatable {
        var fg: Color?
        var bg: Color?
        var fgCode: Int?
        var bold = false
        var dim = false
        var italic = false
        var underline = false
        var inverse = false
    }

    private var style = Style()

    mutating func line(_ input: String) -> LogLine {
        // Progress output overwrites itself with \r. Keep what a terminal would show last.
        let segments = input.split(separator: "\r", omittingEmptySubsequences: true)
        let raw = segments.last.map(String.init) ?? ""

        var out = AttributedString()
        var plain = ""
        var buffer = ""
        var sawColor = false

        func flushBuffer() {
            guard !buffer.isEmpty else { return }
            out += styled(buffer)
            plain += buffer
            buffer = ""
        }

        let scalars = Array(raw.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c == "\u{1B}", i + 1 < scalars.count {
                let kind = scalars[i + 1]
                if kind == "[" {
                    // CSI: parameters, then one final byte in 0x40...0x7E.
                    var j = i + 2
                    var params = ""
                    while j < scalars.count, !(0x40...0x7E).contains(scalars[j].value) {
                        params.unicodeScalars.append(scalars[j]); j += 1
                    }
                    if j < scalars.count, scalars[j] == "m" {
                        flushBuffer()
                        if apply(params) { sawColor = true }
                    }
                    i = j + 1
                    continue
                } else if kind == "]" {
                    // OSC (titles, hyperlinks): skip to BEL or ESC \.
                    var j = i + 2
                    while j < scalars.count {
                        if scalars[j] == "\u{07}" { j += 1; break }
                        if scalars[j] == "\u{1B}", j + 1 < scalars.count, scalars[j + 1] == "\\" { j += 2; break }
                        j += 1
                    }
                    i = j
                    continue
                } else {
                    i += 2
                    continue
                }
            }
            if c.value >= 0x20 || c == "\t" { buffer.unicodeScalars.append(c) }
            i += 1
        }
        flushBuffer()

        if !sawColor, style.fg == nil { out = fallback(out, plain: plain) }
        linkURLs(&out, plain: plain)
        return LogLine(plain: plain, styled: out)
    }

    // MARK: SGR

    /// Applies an SGR sequence. Returns true when it set a color.
    private mutating func apply(_ params: String) -> Bool {
        var codes = params.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        if codes.isEmpty { codes = [0] }
        var setColor = false
        var k = 0
        while k < codes.count {
            let code = codes[k]
            switch code {
            case 0: style = Style()
            case 1: style.bold = true
            case 2: style.dim = true
            case 3: style.italic = true
            case 4: style.underline = true
            case 7: style.inverse = true
            case 22: style.bold = false; style.dim = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 27: style.inverse = false
            case 30...37, 90...97:
                style.fg = Self.basic(code >= 90 ? code - 90 + 8 : code - 30)
                style.fgCode = code
                setColor = true
            case 39: style.fg = nil; style.fgCode = nil
            case 40...47, 100...107:
                style.bg = Self.basic(code >= 100 ? code - 100 + 8 : code - 40)
                setColor = true
            case 49: style.bg = nil
            case 38, 48:
                var color: Color?
                if k + 2 < codes.count, codes[k + 1] == 5 {
                    color = Self.palette256(codes[k + 2]); k += 2
                } else if k + 4 < codes.count, codes[k + 1] == 2 {
                    color = Color(red: Double(codes[k + 2]) / 255, green: Double(codes[k + 3]) / 255,
                                  blue: Double(codes[k + 4]) / 255)
                    k += 4
                }
                if code == 38 { style.fg = color; style.fgCode = nil } else { style.bg = color }
                setColor = true
            default: break
            }
            k += 1
        }
        return setColor
    }

    private func styled(_ text: String) -> AttributedString {
        var a = AttributedString(text)
        var fg = style.fg
        var bg = style.bg
        if style.inverse {
            (fg, bg) = (bg ?? Color(nsColor: .textBackgroundColor), fg ?? .primary)
        }
        // Black text on a colored badge (vitest " PASS ", next " ✓ ").
        if bg != nil, style.fgCode == 30 { fg = .black }
        if let fg { a.foregroundColor = style.dim ? fg.opacity(0.6) : fg }
        else if style.dim { a.foregroundColor = .secondary }
        if let bg { a.backgroundColor = bg }
        if style.bold { a.inlinePresentationIntent = .stronglyEmphasized }
        if style.italic { a.inlinePresentationIntent = (a.inlinePresentationIntent ?? []).union(.emphasized) }
        if style.underline { a.underlineStyle = .single }
        return a
    }

    // MARK: Fallback and links

    private static let errorPattern = try! NSRegularExpression(
        pattern: #"\b(error|errors|err!|failed|failure|fatal|exception|panic|uncaught|unhandled)\b|✗|✘|⨯"#,
        options: [.caseInsensitive])
    private static let warnPattern = try! NSRegularExpression(
        pattern: #"\b(warn|warning|warnings|deprecated)\b|⚠"#, options: [.caseInsensitive])
    private static let urlPattern = try! NSRegularExpression(pattern: #"https?://[^\s'"<>)\]]+"#)

    private func fallback(_ text: AttributedString, plain: String) -> AttributedString {
        let range = NSRange(plain.startIndex..., in: plain)
        var out = text
        if Self.errorPattern.firstMatch(in: plain, range: range) != nil {
            out.foregroundColor = Color(nsColor: .systemRed)
        } else if Self.warnPattern.firstMatch(in: plain, range: range) != nil {
            out.foregroundColor = Color(nsColor: .systemOrange)
        }
        return out
    }

    private func linkURLs(_ text: inout AttributedString, plain: String) {
        for match in Self.urlPattern.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
            guard let r = Range(match.range, in: plain), let url = URL(string: String(plain[r])),
                  let lower = AttributedString.Index(r.lowerBound, within: text),
                  let upper = AttributedString.Index(r.upperBound, within: text) else { continue }
            text[lower..<upper].link = url
            text[lower..<upper].underlineStyle = .single
            if text[lower..<upper].foregroundColor == nil {
                text[lower..<upper].foregroundColor = Color(nsColor: .systemBlue)
            }
        }
    }

    // MARK: Palette

    /// The 16 base colors, tuned to read on both light and dark backgrounds.
    private static func basic(_ index: Int) -> Color {
        switch index {
        case 0: return Color(nsColor: .tertiaryLabelColor)
        case 1, 9: return Color(nsColor: .systemRed)
        case 2, 10: return Color(nsColor: .systemGreen)
        case 3, 11: return Color(nsColor: .systemYellow)
        case 4, 12: return Color(nsColor: .systemBlue)
        case 5, 13: return Color(nsColor: .systemPurple)
        case 6, 14: return Color(nsColor: .systemTeal)
        case 7: return Color(nsColor: .secondaryLabelColor)
        case 8: return Color(nsColor: .secondaryLabelColor)
        default: return .primary
        }
    }

    private static func palette256(_ n: Int) -> Color {
        if n < 16 { return basic(n) }
        if n >= 232 {
            let v = Double(8 + (n - 232) * 10) / 255
            return Color(red: v, green: v, blue: v)
        }
        let i = n - 16
        func level(_ x: Int) -> Double { x == 0 ? 0 : Double(55 + x * 40) / 255 }
        return Color(red: level(i / 36), green: level((i / 6) % 6), blue: level(i % 6))
    }
}
