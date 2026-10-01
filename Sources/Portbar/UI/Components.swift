import SwiftUI

/// Brand mark in a soft tile. Falls back to an SF Symbol.
struct KindIcon: View {
    let kind: ServiceKind
    var size: CGFloat = 26

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .fill(Color.primary.opacity(0.07))
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            if let slug = kind.brand, let shape = BrandShape.named(slug) {
                shape.fill(Color.primary.opacity(0.85))
                    .frame(width: size * 0.52, height: size * 0.52)
            } else {
                Image(systemName: kind.symbol)
                    .font(.system(size: size * 0.46, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

struct PortPill: View {
    let port: UInt16
    var highlighted = false

    var body: some View {
        Text(":\(String(port))")
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .foregroundStyle(highlighted ? .primary : .secondary)
            .padding(.horizontal, 4.5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(highlighted ? 0.10 : 0.05))
            )
            .fixedSize()
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
    }
}

struct BranchChip: View {
    let branch: String
    var linked = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: linked ? "arrow.triangle.branch" : "circle.fill")
                .font(.system(size: linked ? 9 : 4, weight: .semibold))
            Text(branch)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

struct IssueDot: View {
    let issue: Issue
    var body: some View {
        Circle()
            .fill(issue.color)
            .frame(width: 6, height: 6)
    }
}

extension Issue {
    var color: Color { isSevere ? Color(nsColor: .systemRed) : Color(nsColor: .systemOrange) }
}

/// Small icon-only button used in row hover actions.
struct RowIconButton: View {
    let symbol: String
    let help: String
    var role: ButtonRole?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(role == .destructive && hovering ? Color(nsColor: .systemRed) : .secondary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.10 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

enum Format {
    static func uptime(since date: Date, now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(date))
        if s < 60 { return "\(max(s, 0))s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }

    static func bytes(_ b: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .memory)
    }
}

/// A small exit status pill. Neutral for success or a stop you asked for, red for a failure.
struct ExitBadge: View {
    let exit: ExitStatus
    var failed: Bool

    var body: some View {
        let red = Color(nsColor: .systemRed)
        Text(exit.short)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(failed ? AnyShapeStyle(red) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(failed ? red.opacity(0.14) : Color.primary.opacity(0.07)))
            .fixedSize()
            .help(exit.long)
    }
}
