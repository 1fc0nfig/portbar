import SwiftUI

struct ServiceRow: View {
    let service: Service
    let model: AppModel
    @Binding var expandedID: String?
    @State private var hovering = false
    @Environment(\.openWindow) private var openWindow

    private var settings: Settings { model.settings.value }
    private var compact: Bool { settings.density == .compact }
    private var expanded: Bool { expandedID == service.id }
    private var topIssue: Issue? { service.issues.sorted().first }
    private var run: ManagedRun? { model.run(for: service) }

    var body: some View {
        VStack(spacing: 0) {
            row
            if expanded {
                ServiceDetails(service: service, model: model)
                    .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.18).delay(0.06)),
                                            removal: .opacity.animation(.easeIn(duration: 0.1))))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(expanded ? 0.05 : hovering ? 0.045 : 0))
        )
        // The row grows like a drawer. Details never draw over the rows below.
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .padding(.horizontal, 6)
        .opacity(service.exiting ? 0.45 : 1)
        .allowsHitTesting(!service.exiting)
        .contextMenu { ServiceMenu(service: service, model: model) }
    }

    private var row: some View {
        HStack(spacing: compact ? 8 : 10) {
            KindIcon(kind: service.kind, size: compact ? 18 : 26)

            if compact {
                HStack(spacing: 6) {
                    title
                    ports
                    if let issue = topIssue { IssueDot(issue: issue).help(issue.label) }
                    if settings.showCommand { commandText }
                }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        title
                        ports
                        if let dir = service.relativeDirectory {
                            Text(dir)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    HStack(spacing: 5) {
                        if let issue = topIssue {
                            IssueDot(issue: issue)
                            Text(issue.label)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(issue.color)
                            if settings.showCommand { Text("·").foregroundStyle(.tertiary).font(.system(size: 11)) }
                        }
                        if settings.showCommand { commandText }
                    }
                }
            }

            Spacer(minLength: 6)

            if settings.showSparkline, let samples = model.cpuHistory[service.id] {
                Sparkline(samples: samples, alert: service.issues.contains(.busy))
            }
            if settings.showMemory {
                Text(Format.bytes(service.memoryBytes))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(width: 58, alignment: .trailing)
            }

            trailing
                .frame(width: run != nil ? 70 : 48, alignment: .trailing)
        }
        .padding(.leading, compact ? 24 : 8)
        .padding(.trailing, 8)
        .padding(.vertical, compact ? 4 : 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            withAnimation(.smooth(duration: 0.28)) { expandedID = expanded ? nil : service.id }
        }
    }

    /// Ports sit next to the name: they identify the service. Clicking one opens it.
    @ViewBuilder private var ports: some View {
        if !service.ports.isEmpty {
            HStack(spacing: 3) {
                let shown = service.ports.count > 2 ? 1 : service.ports.count
                ForEach(service.ports.prefix(shown), id: \.self) { port in
                    Button { ProcessControl.open(service, port: port) } label: {
                        PortPill(port: port, highlighted: hovering)
                    }
                    .buttonStyle(.plain)
                    .help("Open http://localhost:\(String(port))")
                }
                if service.ports.count > shown {
                    Text("+\(service.ports.count - shown)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .fixedSize()
        }
    }

    private var title: some View {
        Text(service.kind.name)
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .fixedSize()
    }

    private var commandText: some View {
        Text(service.command)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    @ViewBuilder private var trailing: some View {
        if hovering {
            HStack(spacing: 2) {
                if let run {
                    RowIconButton(symbol: "text.alignleft", help: "Show logs") {
                        openWindow(id: "logs", value: run.id)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
                if !service.ports.isEmpty {
                    RowIconButton(symbol: "arrow.up.right", help: "Open in browser") {
                        ProcessControl.open(service)
                    }
                }
                RowIconButton(symbol: "xmark", help: "Stop", role: .destructive) {
                    model.stop(service, includeLaunchers: run != nil)
                }
            }
        } else if settings.showUptime {
            HStack(spacing: 4) {
                if run != nil {
                    Image(systemName: "play.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.tertiary)
                        .help("Started from portbar")
                }
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    Text(Format.uptime(since: service.startTime, now: ctx.date))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

struct ServiceDetails: View {
    let service: Service
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var showFullCommand = false

    var body: some View {
        let run = model.run(for: service)
        VStack(alignment: .leading, spacing: 10) {
            if let issue = service.issues.sorted().first {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    IssueDot(issue: issue)
                    Text(issue.explanation)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            stats

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                if let dir = service.directory {
                    detail("Directory", (dir as NSString).abbreviatingWithTildeInPath)
                }
                if let run {
                    detail("Script", "\(run.command)  (started from portbar)")
                } else if service.fromEarlierSession, let launcher = service.launcherCommand {
                    detail("Script", "\(launcher)  (started from portbar earlier, logs not available)")
                } else if let launcher = service.launcherCommand {
                    detail("Started by", launcher)
                }
                commandRow
                detail("PID", service.members.count > 1
                       ? "\(service.root.pid)  +\(service.members.count - 1) child processes"
                       : "\(service.root.pid)")
            }

            actions(run)
        }
        .padding(.leading, 44)
        .padding(.trailing, 10)
        .padding(.bottom, 10)
        .padding(.top, 2)
    }

    private var stats: some View {
        HStack(spacing: 6) {
            let cpu = model.cpuHistory[service.id] ?? []
            let memory = model.memoryHistory[service.id] ?? []
            StatTile(label: "CPU", value: "\(Int(service.cpuPercent.rounded()))%",
                     alert: service.issues.contains(.busy)) {
                Sparkline(samples: cpu, alert: service.issues.contains(.busy), width: 64, height: 20, track: false)
            }
            StatTile(label: "Memory", value: Format.bytes(service.memoryBytes)) {
                Sparkline(samples: memory, width: 64, height: 20, relative: true, track: false,
                          help: "Memory, last \(memory.count) samples")
            }
            StatTile(label: "Uptime", value: Format.uptime(since: service.startTime)) { EmptyView() }
                .fixedSize()
                .help(service.startTime.formatted(date: .abbreviated, time: .standard))
            StatTile(label: "Procs", value: "\(service.members.count)") { EmptyView() }
                .fixedSize()
        }
    }

    /// Icon buttons with tooltips. Open is the one accent button, Stop the one red button.
    private func actions(_ run: ManagedRun?) -> some View {
        HStack(spacing: 4) {
            if let port = service.ports.first {
                Button { ProcessControl.open(service) } label: { ActionIcon(systemName: "arrow.up.right.square") }
                    .buttonStyle(.borderedProminent)
                    .tint(.accentColor)
                    .help("Open http://localhost:\(port)")
                Button { ProcessControl.copy("http://localhost:\(port)") } label: { ActionIcon(systemName: "link") }
                    .help("Copy http://localhost:\(port)")
            }
            if let run {
                Button {
                    openWindow(id: "logs", value: run.id)
                    NSApp.activate(ignoringOtherApps: true)
                } label: { ActionIcon(systemName: "text.alignleft") }
                .help("Show logs")
            }
            if service.rerun != nil || run != nil {
                Button { model.restart(service) } label: { ActionIcon(systemName: "arrow.clockwise") }
                    .help(run == nil ? "Restart inside portbar, with logs" : "Restart")
            }
            if let dir = service.location?.worktreeRoot ?? service.directory {
                Button { ProcessControl.revealInFinder(dir) } label: { ActionIcon(systemName: "folder") }
                    .help("Show in Finder")
                if let editor = ProcessControl.editor {
                    Button { ProcessControl.openInEditor(dir) } label: {
                        Image(nsImage: ProcessControl.editorIcon ?? NSImage())
                            .resizable()
                            .frame(width: 14, height: 14)
                            .frame(width: 18, height: 16)
                    }
                    .help("Open in \(editor.name)")
                }
            }
            Spacer(minLength: 4)
            StopButton(service: service, model: model, run: run)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    @ViewBuilder
    private func detail(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .gridColumnAlignment(.leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(value)
                .contextMenu { Button("Copy") { ProcessControl.copy(value) } }
        }
    }

    /// The full command can be long. It shows two lines, and a click shows all of it.
    private var commandRow: some View {
        let command = service.root.args.joined(separator: " ")
        return GridRow(alignment: .firstTextBaseline) {
            Text("Command")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text(command)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(showFullCommand ? nil : 2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.smooth(duration: 0.25)) { showFullCommand.toggle() } }
                .help(showFullCommand ? "Click to collapse" : "Click to show the full command")
                .contextMenu { Button("Copy Command") { ProcessControl.copy(command) } }
        }
    }
}

/// A fixed-size SF Symbol, so icon buttons line up.
struct ActionIcon: View {
    let systemName: String
    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: .medium))
            .frame(width: 18, height: 16)
    }
}

/// Red Stop with a menu for the stronger variants.
struct StopButton: View {
    let service: Service
    let model: AppModel
    let run: ManagedRun?

    private let red = Color(nsColor: .systemRed)

    /// One split control: Stop on the left, other ways to stop behind the chevron.
    var body: some View {
        HStack(spacing: 0) {
            Button {
                model.stop(service, includeLaunchers: run != nil)
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10))
                    .padding(.leading, 8)
                    .padding(.trailing, PanelView.isRendering ? 8 : 6)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(run != nil ? "Stop the script" : "Stop")
            if !PanelView.isRendering {
                Rectangle().fill(red.opacity(0.3)).frame(width: 1, height: 12)
                Menu {
                    if !service.launchers.isEmpty || run != nil {
                        Button("Stop Whole Run") { model.stop(service, includeLaunchers: true) }
                    }
                    Button("Force Kill") { model.stop(service, includeLaunchers: true, force: true) }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .tint(red)
                .frame(width: 20)
                .help("More ways to stop")
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(red)
        .frame(height: 20)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(red.opacity(0.12)))
        .fixedSize()
    }
}

/// Small stat block in the details: label, value, optional chart.
struct StatTile<Chart: View>: View {
    let label: String
    let value: String
    var alert = false
    @ViewBuilder let chart: () -> Chart

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
            HStack(alignment: .bottom, spacing: 6) {
                Text(value)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(alert ? AnyShapeStyle(Color(nsColor: .systemRed)) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .fixedSize()
                chart()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }
}

/// A service you stopped. Dimmed, with Run again.
struct StoppedRow: View {
    let entry: StoppedEntry
    let model: AppModel
    @State private var hovering = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let compact = model.settings.value.density == .compact
        HStack(spacing: compact ? 8 : 10) {
            KindIcon(kind: entry.kind, size: compact ? 18 : 26)
                .opacity(0.45)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(entry.kind.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    if let run = entry.run, let exit = run.exit {
                        ExitBadge(exit: exit, failed: run.failed)
                    }
                }
                if !compact {
                    TimelineView(.periodic(from: .now, by: 30)) { ctx in
                        Text("\(entry.exited ? "Exited" : "Stopped") \(Format.uptime(since: entry.stoppedAt, now: ctx.date)) ago"
                             + (entry.command.map { " · \($0)" } ?? ""))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            Spacer(minLength: 6)
            HStack(spacing: 2) {
                if let run = entry.run {
                    RowIconButton(symbol: "text.alignleft", help: "Show logs") {
                        openWindow(id: "logs", value: run.id)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
                RowIconButton(symbol: "minus", help: "Dismiss") { model.dismiss(entry) }
            }
            .opacity(hovering ? 1 : 0)
            if entry.command != nil {
                Button { model.runAgain(entry) } label: {
                    Label("Run", systemImage: "play.fill")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Run again: \(entry.command ?? "")")
            }
        }
        .padding(.leading, compact ? 24 : 8)
        .padding(.trailing, 8)
        .padding(.vertical, compact ? 4 : 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.045 : 0))
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            if entry.command != nil { Button("Run Again") { model.runAgain(entry) } }
            Button("Dismiss") { model.dismiss(entry) }
            if !entry.projectID.hasPrefix("~") {
                Divider()
                Button("Project Settings…") { model.showSettings(.projects, project: entry.projectID) }
            }
        }
    }
}

struct ServiceMenu: View {
    let service: Service
    let model: AppModel

    var body: some View {
        if !service.ports.isEmpty {
            ForEach(service.ports, id: \.self) { port in
                Button("Open localhost:\(String(port))") { ProcessControl.open(service, port: port) }
            }
            Button("Copy URL") { ProcessControl.copy("http://localhost:\(service.ports[0])") }
            Divider()
        }
        Button("Copy PID") { ProcessControl.copy("\(service.root.pid)") }
        Button("Copy Command") { ProcessControl.copy(service.root.args.joined(separator: " ")) }
        if let dir = service.directory {
            Button("Reveal in Finder") { ProcessControl.revealInFinder(dir) }
            if let editor = ProcessControl.editor {
                Button("Open in \(editor.name)") {
                    ProcessControl.openInEditor(service.location?.worktreeRoot ?? dir)
                }
            }
        }
        Divider()
        Button("Stop") { model.stop(service) }
        if !service.launchers.isEmpty || model.run(for: service) != nil {
            Button("Stop Whole Run") { model.stop(service, includeLaunchers: true) }
        }
        Button("Force Kill") { model.stop(service, includeLaunchers: true, force: true) }
        Divider()
        if let repo = service.location?.repoRoot {
            Button("Project Settings…") { model.showSettings(.projects, project: repo) }
        }
        if !service.issues.isEmpty {
            Button("Alert Settings…") { model.showSettings(.general) }
        }
        let pattern = (service.root.executable as NSString).lastPathComponent
        if service.location == nil, !pattern.isEmpty {
            Divider()
            Button("Hide \(pattern) Processes") {
                model.settings.value.ignorePatterns.append(pattern)
                model.refresh()
            }
        }
    }
}

/// A script started from portbar that has no service row: still booting, a one-shot script, or finished.
struct RunRow: View {
    let run: ManagedRun
    let model: AppModel
    @State private var hovering = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let compact = model.settings.value.density == .compact
        let tile: CGFloat = compact ? 18 : 26
        HStack(spacing: compact ? 8 : 10) {
            ZStack {
                RoundedRectangle(cornerRadius: tile * 0.23, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
                if run.isRunning {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: run.failed ? "xmark" : "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(run.failed ? Color(nsColor: .systemRed) : .secondary)
                }
            }
            .frame(width: tile, height: tile)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(run.name)
                        .font(.system(size: 13, weight: .medium))
                    if let exit = run.exit { ExitBadge(exit: exit, failed: run.failed) }
                }
                Text(status)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(run.failed ? AnyShapeStyle(Color(nsColor: .systemRed)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            HStack(spacing: 2) {
                RowIconButton(symbol: "text.alignleft", help: "Show logs") {
                    openWindow(id: "logs", value: run.id)
                    NSApp.activate(ignoringOtherApps: true)
                }
                if run.isRunning {
                    RowIconButton(symbol: "xmark", help: "Stop", role: .destructive) { model.stop(run) }
                } else {
                    RowIconButton(symbol: "arrow.clockwise", help: "Run again") { model.runner.restart(run) }
                    RowIconButton(symbol: "minus", help: "Dismiss") { model.runner.dismiss(run) }
                }
            }
            .opacity(hovering || !run.isRunning ? 1 : 0.6)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, compact ? 4 : 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.045 : 0))
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Show Logs") {
                openWindow(id: "logs", value: run.id)
                NSApp.activate(ignoringOtherApps: true)
            }
            if run.isRunning { Button("Stop") { model.stop(run) } } else { Button("Run Again") { model.runner.restart(run) } }
            Divider()
            Button("Project Settings…") { model.showSettings(.projects, project: run.projectID) }
        }
    }

    private var status: String {
        if run.isRunning {
            return run.log.lines.last { !$0.plain.trimmingCharacters(in: .whitespaces).isEmpty }?.plain ?? run.command
        }
        let verb = run.stoppedByUser ? "Stopped" : run.failed ? "Failed" : "Done"
        return "\(verb) · \(run.command)"
    }
}
