import SwiftUI

struct PanelView: View {
    let model: AppModel
    /// ImageRenderer cannot draw ScrollView or Menu. `--render` sets this.
    nonisolated(unsafe) static var isRendering = false
    @State private var expandedID: String?
    @State private var addingProject = false
    @Environment(\.openSettings) private var openSettings

    init(model: AppModel, expandedID: String? = nil) {
        self.model = model
        _expandedID = State(initialValue: expandedID)
    }

    var body: some View {
        let projects = model.projects
        VStack(spacing: 0) {
            header(projects)
            Divider().opacity(0.6)
            if projects.isEmpty {
                empty
            } else if Self.isRendering {
                list(projects)
            } else {
                ScrollView { list(projects) }
                    .scrollIndicators(.never)
                    .frame(maxHeight: model.settings.value.panelMaxHeight)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.issueCount > 0 { issueBar }
        }
        .frame(width: model.settings.value.panelWidth)
        .overlay(alignment: .bottomTrailing) {
            if !Self.isRendering { ResizeGrip(settings: model.settings) }
        }
        // Keep the vibrancy, but stop bright windows behind the panel from showing through.
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.55))
        .onAppear { model.openSettingsAction = openSettings }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.isPanelOpen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            model.isPanelOpen = false
        }
    }

    private func list(_ projects: [ProjectDisplay]) -> some View {
        // A plain VStack, so rows fade and slide in place when the list changes.
        VStack(alignment: .leading, spacing: 0) {
            ForEach(projects) { project in
                ProjectSection(project: project, model: model, expandedID: $expandedID)
                    .transition(.opacity)
            }
        }
        .padding(.bottom, 8)
    }

    private func header(_ projects: [ProjectDisplay]) -> some View {
        HStack(spacing: 8) {
            Text("portbar")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(summary(projects))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
            if !Self.isRendering {
                Button { addingProject.toggle() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Add a project")
                .popover(isPresented: $addingProject, arrowEdge: .bottom) { AddProjectView(model: model) }
            }
            if Self.isRendering {
                menuGlyph
            } else {
                Menu {
                    Button("Settings…") { model.showSettings(model.settingsTab) }
                    .keyboardShortcut(",")
                    Picker("Sort Projects By", selection: Binding(get: { model.settings.value.projectSort },
                                                                  set: { model.settings.value.projectSort = $0 })) {
                        ForEach(ProjectSort.allCases) { Text($0.label).tag($0) }
                    }
                    Button("Refresh") { model.refresh(probe: true) }.keyboardShortcut("r")
                    Button("Clear All Finished") { model.clearFinished() }.disabled(!model.hasFinished)
                    Divider()
                    Button("Quit portbar") { NSApp.terminate(nil) }.keyboardShortcut("q")
                } label: { menuGlyph }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Panel Settings…") { model.showSettings(.panel) }
            Button("Menu Bar Settings…") { model.showSettings(.general) }
            Button("Project Folders…") { model.showSettings(.projects) }
            Button("Hidden Items…") { model.showSettings(.hidden) }
        }
    }

    private var menuGlyph: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
    }

    private func summary(_ projects: [ProjectDisplay]) -> String {
        let services = projects.flatMap(\.services)
        let ports = services.reduce(0) { $0 + $1.ports.count }
        return "\(services.count) \(services.count == 1 ? "service" : "services") · \(ports) \(ports == 1 ? "port" : "ports")"
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
            Text("Nothing running")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Click + to add projects, or pin them in Settings.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var issueBar: some View {
        let detached = model.snapshot.services.filter { $0.issues.contains(.detached) || $0.issues.contains(.forgotten) }.count
        return VStack(spacing: 0) {
            Divider().opacity(0.6)
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(nsColor: model.hasSevereIssue ? .systemRed : .systemOrange))
                Text("\(model.issueCount) need attention")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if detached > 0 {
                    Button("Stop \(detached) detached") { model.stopAllDetached() }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .contextMenu { Button("Alert Settings…") { model.showSettings(.general) } }
        }
    }
}

struct ProjectSection: View {
    let project: ProjectDisplay
    let model: AppModel
    @Binding var expandedID: String?
    @State private var showsOlder = false

    private var singleWorktree: WorktreeGroup? {
        project.worktrees.count == 1 && !project.worktrees[0].isLinked ? project.worktrees[0] : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(project.worktrees) { worktree in
                if singleWorktree == nil, let branch = worktree.branch {
                    HStack(spacing: 6) {
                        BranchChip(branch: branch, linked: worktree.isLinked)
                        if worktree.isLinked, let path = worktree.path {
                            Text((path as NSString).abbreviatingWithTildeInPath)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.quaternary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        Spacer()
                        if let path = worktree.path, worktree.isLinked {
                            ScriptsMenu(project: project, directory: path, model: model)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
                    .padding(.bottom, 2)
                }
                ForEach(worktree.services) { service in
                    ServiceRow(service: service, model: model, expandedID: $expandedID)
                        .transition(.opacity)
                }
            }
            ForEach(project.activeRuns) { run in
                RunRow(run: run, model: model)
            }
            // The newest finished row stays in view. Older ones fold under one line.
            let finished = project.finished
            if let newest = finished.first {
                finishedRow(newest)
            }
            if finished.count > 1 {
                let older = Array(finished.dropFirst())
                OlderToggle(older: older, expanded: $showsOlder)
                if showsOlder {
                    ForEach(older) { finishedRow($0) }
                }
            }
        }
    }

    @ViewBuilder
    private func finishedRow(_ item: FinishedItem) -> some View {
        switch item {
        case .stopped(let entry): StoppedRow(entry: entry, model: model).transition(.opacity)
        case .run(let run): RunRow(run: run, model: model).transition(.opacity)
        }
    }

    private var header: some View {
        let running = project.isRunning
        return HStack(spacing: 7) {
            if model.settings.value.showProjectIcons {
                ProjectIcon(project: project, model: model, size: 16)
                    .opacity(running ? 1 : 0.55)
            }
            Text(project.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(running ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(1)
            if let w = singleWorktree, let branch = w.branch {
                BranchChip(branch: branch)
            }
            Spacer(minLength: 6)
            if project.hasFinished, !PanelView.isRendering {
                ClearButton { model.clearFinished(in: project.id) }
            }
            if let path = project.path {
                let favorites = project.pinned ? Array(model.catalog.favorites(in: path, config: project.config).prefix(2)) : []
                if favorites.isEmpty {
                    ScriptsMenu(project: project, directory: path, model: model)
                } else {
                    HStack(spacing: 0) {
                        ForEach(favorites) { script in
                            ScriptChip(script: script, project: project, directory: path, model: model)
                            Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 0.5, height: 12)
                        }
                        ScriptsMenu(project: project, directory: path, model: model, attached: true)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .contextMenu {
            if project.hasFinished {
                Button("Clear Finished") { model.clearFinished(in: project.id) }
                Divider()
            }
            if let path = project.path {
                Button(project.pinned ? "Unpin" : "Pin to Top") { model.settings.setPinned(path, !project.pinned) }
                if project.config?.added == true || project.pinned {
                    Button("Remove from List") { model.settings.removeFromList(path) }
                } else {
                    Button("Keep in List") { model.settings.add(path) }
                }
                Button("Hide Project") {
                    model.settings.update(path) { $0.hidden = true; $0.pinned = false; $0.added = false }
                }
                Divider()
                Button("Reveal in Finder") { ProcessControl.revealInFinder(path) }
                if let editor = ProcessControl.editor {
                    Button("Open in \(editor.name)") { ProcessControl.openInEditor(path) }
                }
                Divider()
                Button("Project Settings…") { model.showSettings(.projects, project: path) }
            }
        }
    }
}

/// Folds the older finished rows of a project: "3 earlier · 1 failed".
struct OlderToggle: View {
    let older: [FinishedItem]
    @Binding var expanded: Bool
    @State private var hovering = false

    var body: some View {
        let failed = older.filter(\.failed).count
        Button {
            withAnimation(.smooth(duration: 0.25)) { expanded.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Text("\(older.count) earlier")
                if failed > 0 {
                    Text("· \(failed) failed").foregroundStyle(Color(nsColor: .systemRed))
                }
                Spacer()
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(hovering ? .secondary : .tertiary)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(expanded ? "Hide earlier runs" : "Show earlier runs")
    }
}

/// Removes the finished rows of one project.
struct ClearButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("Clear")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hovering ? .secondary : .tertiary)
                .padding(.horizontal, 6)
                .frame(height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.07 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Clear stopped and finished scripts")
    }
}

struct ScriptChip: View {
    let script: ProjectScript
    let project: ProjectDisplay
    let directory: String
    let model: AppModel
    @State private var hovering = false

    var body: some View {
        let active = model.runner.activeRun(projectID: project.id, directory: directory, name: script.name)
        Button {
            if let active { model.stop(active) } else { model.start(script, projectID: project.id, directory: directory) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: active != nil ? "stop.fill" : "play.fill")
                    .font(.system(size: 7))
                Text(script.name)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(active != nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(active != nil ? 0.10 : hovering ? 0.07 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(active != nil ? "Stop \(script.command)" : "\(script.command)\n\(script.detail)")
    }
}

/// Play menu with every script of a project or worktree. Common scripts first, the rest in a submenu.
struct ScriptsMenu: View {
    let project: ProjectDisplay
    let directory: String
    let model: AppModel
    /// Sits inside the script pill: shows a small chevron instead of a play icon.
    var attached = false
    @Environment(\.openSettings) private var openSettings

    private static let common: Set = ["dev", "start", "build", "test", "lint", "typecheck", "preview", "storybook"]

    var body: some View {
        let scripts = model.catalog.scripts(in: directory, config: project.config)
        if !scripts.isEmpty, !PanelView.isRendering {
            let favorites = Set(project.config?.favoriteScripts ?? ["dev"])
            let primary = scripts.filter { $0.isCustom || favorites.contains($0.name) || Self.common.contains($0.name) }
            let rest = scripts.filter { s in !primary.contains(s) }
            Menu {
                ForEach(primary) { item($0) }
                if !rest.isEmpty {
                    Divider()
                    Menu("More Scripts") { ForEach(rest) { item($0) } }
                }
                Divider()
                Button("Edit Scripts…") { model.showSettings(.projects, project: project.path) }
            } label: {
                Image(systemName: attached ? "chevron.down" : "play.circle")
                    .font(.system(size: attached ? 8 : 13, weight: attached ? .bold : .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: attached ? 18 : 20, height: attached ? 18 : 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(attached ? "All scripts" : "Run a script")
        }
    }

    @ViewBuilder
    private func item(_ script: ProjectScript) -> some View {
        let active = model.runner.activeRun(projectID: project.id, directory: directory, name: script.name)
        Button {
            if let active { model.stop(active) } else { model.start(script, projectID: project.id, directory: directory) }
        } label: {
            if active != nil {
                Label("Stop \(script.name)", systemImage: "stop.fill")
            } else {
                Text(script.name) + Text("   " + Self.short(script.detail)).foregroundStyle(.secondary)
            }
        }
        .help(script.detail)
    }

    /// One short line: at most 34 characters, cut in the middle of long paths and flags.
    static func short(_ text: String) -> String {
        let t = text.replacingOccurrences(of: "\n", with: " ")
        guard t.count > 34 else { return t }
        return String(t.prefix(33)) + "…"
    }
}

/// Corner grip: drag to set the panel width and maximum height. Double-click to reset.
struct ResizeGrip: View {
    let settings: SettingsStore
    @State private var start: (width: Double, height: Double)?
    @State private var hovering = false

    var body: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 8, weight: .semibold))
            .rotationEffect(.degrees(90))
            .foregroundStyle(hovering || start != nil ? .secondary : .quaternary)
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside {
                    if #available(macOS 15.0, *) {
                        NSCursor.frameResize(position: .bottomRight, directions: .all).push()
                    } else {
                        NSCursor.crosshair.push()
                    }
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let s = start ?? (settings.value.panelWidth, settings.value.panelMaxHeight)
                        if start == nil { start = s }
                        let w = (s.width + value.translation.width).clamped(to: Settings.widthRange)
                        let h = (s.height + value.translation.height).clamped(to: Settings.heightRange)
                        // Round to whole points, so the panel does not redraw for sub-point moves.
                        settings.value.panelWidth = w.rounded()
                        settings.value.panelMaxHeight = h.rounded()
                    }
                    .onEnded { _ in start = nil }
            )
            .onTapGesture(count: 2) {
                settings.value.panelWidth = Settings.defaultWidth
                settings.value.panelMaxHeight = Settings.defaultMaxHeight
            }
            .help("Drag to resize. Double-click to reset.")
            .padding(2)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
