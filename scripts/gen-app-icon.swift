// Draws the app icon: the 2×2 dot grid from the menu bar on a dark tile.
// swift scripts/gen-app-icon.swift  →  assets/brand/app-icon-1024.png and assets/brand/AppIcon.icns
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let brand = root.appendingPathComponent("assets/brand")

func draw(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // macOS icon grid: an 824 pt tile centered in 1024, corner radius about 185.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSColor(white: 0.09, alpha: 1).setFill()
    shape.fill()
    NSColor(white: 1, alpha: 0.08).setStroke()
    shape.lineWidth = 4 * s
    shape.stroke()

    // Three running projects and one empty slot, like the menu bar mark.
    let dot: CGFloat = 164 * s, gap: CGFloat = 112 * s
    let origin = (1024 * s - (dot * 2 + gap)) / 2
    let alphas: [CGFloat] = [1, 1, 1, 0.28]
    for i in 0..<4 {
        let col = CGFloat(i % 2), row = CGFloat(1 - i / 2)
        let rect = NSRect(x: origin + col * (dot + gap), y: origin + row * (dot + gap), width: dot, height: dot)
        NSColor(white: 1, alpha: alphas[i]).setFill()
        NSBezierPath(ovalIn: rect).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

try? FileManager.default.createDirectory(at: brand, withIntermediateDirectories: true)
try draw(1024).representation(using: .png, properties: [:])!.write(to: brand.appendingPathComponent("app-icon-1024.png"))

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try draw(CGFloat(base * scale)).representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent(name))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", brand.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print("wrote assets/brand/app-icon-1024.png and AppIcon.icns")
