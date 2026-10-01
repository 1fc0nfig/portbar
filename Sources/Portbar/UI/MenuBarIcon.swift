import AppKit
import SwiftUI

/// Draws the menu bar mark.
enum MenuBarIcon {
    /// 2×2 dots. Filled = running, ring = pinned but stopped, faint = free slot, orange = warning, red = critical.
    static func dots(_ states: [DotState]) -> NSImage {
        let hasIssue = states.contains(where: \.isIssue)
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { _ in
            let d: CGFloat = 5.5
            let gap: CGFloat = 2.5
            let origin = (16 - (2 * d + gap)) / 2
            let ink = hasIssue ? NSColor.labelColor : NSColor.black

            for (i, state) in states.prefix(4).enumerated() {
                let rect = NSRect(x: origin + CGFloat(i % 2) * (d + gap),
                                  y: origin + CGFloat(i / 2) * (d + gap), width: d, height: d)
                switch state {
                case .running:
                    ink.setFill()
                    NSBezierPath(ovalIn: rect).fill()
                case .warning:
                    NSColor.systemOrange.setFill()
                    NSBezierPath(ovalIn: rect).fill()
                case .critical:
                    NSColor.systemRed.setFill()
                    NSBezierPath(ovalIn: rect).fill()
                case .stopped:
                    let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.65, dy: 0.65))
                    ring.lineWidth = 1.3
                    ink.withAlphaComponent(0.9).setStroke()
                    ring.stroke()
                case .empty:
                    ink.withAlphaComponent(0.28).setFill()
                    NSBezierPath(ovalIn: rect.insetBy(dx: 1.4, dy: 1.4)).fill()
                }
            }
            return true
        }
        image.isTemplate = !hasIssue
        return image
    }
}

struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        switch model.settings.value.menuBarStyle {
        case .dotGrid:
            Image(nsImage: MenuBarIcon.dots(model.dots))
        case .icon:
            Image(systemName: model.issueCount > 0 ? "exclamationmark.triangle" : "server.rack")
        case .iconCount:
            let count = model.visibleServiceCount
            HStack(spacing: 3) {
                Image(systemName: model.issueCount > 0 ? "exclamationmark.triangle" : "server.rack")
                if count > 0 { Text("\(count)").monospacedDigit() }
            }
        }
    }
}

/// History line. CPU scales from zero, memory scales between its own minimum and maximum.
struct Sparkline: View {
    let samples: [Double]
    var alert = false
    var width: CGFloat = 34
    var height: CGFloat = 14
    /// Scale between min and max instead of from zero. Shows small memory changes.
    var relative = false
    /// Faint box behind the line, so an idle chart still reads as a chart.
    var track = true
    var help: String?

    var body: some View {
        Canvas { ctx, size in
            guard samples.count > 1 else { return }
            let top = relative ? (samples.max() ?? 1) : max(samples.max() ?? 0, 10)
            let bottom = relative ? (samples.min() ?? 0) : 0
            let span = max(top - bottom, relative ? max(top * 0.02, 1) : 1)
            let step = size.width / CGFloat(max(samples.count - 1, 1))
            // Right-align so the newest sample always sits at the right edge.
            let offset = size.width - step * CGFloat(samples.count - 1)
            var line = Path()
            for (i, v) in samples.enumerated() {
                let y = size.height - 1 - CGFloat((v - bottom) / span) * (size.height - 2)
                let p = CGPoint(x: offset + CGFloat(i) * step, y: y)
                if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
            }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: offset, y: size.height))
            area.closeSubpath()
            let color: Color = alert ? Color(nsColor: .systemRed) : .primary
            ctx.fill(area, with: .color(color.opacity(0.10)))
            ctx.stroke(line, with: .color(color.opacity(alert ? 0.9 : 0.45)), lineWidth: 1)
        }
        .frame(width: width, height: height)
        .padding(track ? 2 : 0)
        .background(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.primary.opacity(track && samples.count > 1 ? 0.05 : 0))
        )
        .help(help ?? "CPU \(Int((samples.last ?? 0).rounded()))%")
    }
}

/// Project icon: favicon or app icon from the repository, a custom file, or a framework mark.
struct ProjectIcon: View {
    let project: ProjectDisplay
    let model: AppModel
    var size: CGFloat = 16

    /// The chosen framework, else the first one found in the files, else the running service.
    private var frameworkKind: ServiceKind? {
        let detected = project.path.map { model.catalog.frameworks(in: $0) } ?? []
        if let id = project.config?.frameworkID, let chosen = detected.first(where: { $0.id == id }) { return chosen }
        return detected.first ?? project.services.first?.kind
    }

    var body: some View {
        let mode = project.config?.iconMode ?? .auto
        if let path = project.path, mode != .none, mode != .framework,
           let image = model.catalog.icon(for: project.config, repoRoot: path) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else if mode != .none, let kind = frameworkKind {
            KindIcon(kind: kind, size: size)
        } else {
            Image(systemName: project.isOther ? "square.dashed" : "folder")
                .font(.system(size: size * 0.7))
                .foregroundStyle(.tertiary)
                .frame(width: size, height: size)
        }
    }
}
