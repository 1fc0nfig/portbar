import AppKit
import SwiftUI

struct SettingsView: View {
    let model: AppModel

    var body: some View {
        TabView(selection: Binding(get: { model.settingsTab }, set: { model.settingsTab = $0 })) {
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            PanelSettings(model: model)
                .tabItem { Label("Panel", systemImage: "rectangle.grid.1x2") }
                .tag(SettingsTab.panel)
            ProjectsSettings(model: model)
                .tabItem { Label("Projects", systemImage: "folder") }
                .tag(SettingsTab.projects)
            IgnoreSettings(model: model)
                .tabItem { Label("Hidden", systemImage: "eye.slash") }
                .tag(SettingsTab.hidden)
        }
        .frame(width: 680, height: 500)
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Bindable var settings: SettingsStore
    let model: AppModel

    init(model: AppModel) {
        self.model = model
        self.settings = model.settings
    }

    var body: some View {
        Form {
            Section("Menu bar") {
                Picker("Style", selection: $settings.value.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases) { style in
                        HStack(spacing: 8) {
                            MenuBarPreview(style: style)
                            Text(style.label)
                        }
                        .tag(style)
                    }
                }
                .pickerStyle(.radioGroup)
                Text("The dot grid shows your pinned projects in order: filled when running, a ring when stopped, orange when something needs attention. Free dots show other running projects.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Behavior") {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                Picker("Refresh while open", selection: $settings.value.refreshInterval) {
                    Text("1 second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                    Text("5 seconds").tag(5.0)
                }
                Toggle("Stop scripts started from portbar when it quits", isOn: $settings.value.stopScriptsOnQuit)
            }
            Section {
                Picker("Mark detached processes red after", selection: $settings.value.forgottenAfterHours) {
                    Text("1 hour").tag(1.0)
                    Text("6 hours").tag(6.0)
                    Text("12 hours").tag(12.0)
                    Text("1 day").tag(24.0)
                    Text("3 days").tag(72.0)
                    Text("Never").tag(0.0)
                }
            } header: {
                Text("Alerts")
            } footer: {
                Text("Orange: detached, the terminal that started it is gone. Red: high CPU, not responding, or detached for longer than the time above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct MenuBarPreview: View {
    let style: MenuBarStyle
    var body: some View {
        Group {
            switch style {
            case .dotGrid:
                Image(nsImage: MenuBarIcon.dots([.running, .warning, .stopped, .empty]))
            case .icon:
                Image(systemName: "server.rack")
            case .iconCount:
                HStack(spacing: 2) { Image(systemName: "server.rack"); Text("3") }
            }
        }
        .font(.system(size: 12))
        .frame(width: 34, height: 18)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)))
    }
}

// MARK: - Panel

private struct PanelSettings: View {
    @Bindable var settings: SettingsStore

    init(model: AppModel) { settings = model.settings }

    var body: some View {
        Form {
            Section("Layout") {
                Picker("Density", selection: $settings.value.density) {
                    ForEach(Density.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Width") {
                    HStack {
                        Slider(value: $settings.value.panelWidth, in: Settings.widthRange, step: 10)
                        Text("\(Int(settings.value.panelWidth)) pt").monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                LabeledContent("Max height") {
                    HStack {
                        Slider(value: $settings.value.panelMaxHeight, in: Settings.heightRange, step: 20)
                        Text("\(Int(settings.value.panelMaxHeight)) pt").monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                Button("Reset Size") {
                    settings.value.panelWidth = Settings.defaultWidth
                    settings.value.panelMaxHeight = Settings.defaultMaxHeight
                }
            }
            Section("Each service shows") {
                Toggle("Command line", isOn: $settings.value.showCommand)
                Toggle("CPU sparkline", isOn: $settings.value.showSparkline)
                Toggle("Memory", isOn: $settings.value.showMemory)
                Toggle("Uptime", isOn: $settings.value.showUptime)
            }
            Section("Projects") {
                Picker("Sort projects by", selection: $settings.value.projectSort) {
                    ForEach(ProjectSort.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Project icons", isOn: $settings.value.showProjectIcons)
                Toggle("Show processes outside repositories", isOn: $settings.value.showOther)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Projects

private struct ProjectsSettings: View {
    let model: AppModel
    private var selection: String? {
        get { model.settingsProject }
        nonmutating set { model.settingsProject = newValue }
    }
    private var selectionBinding: Binding<String?> {
        Binding(get: { model.settingsProject }, set: { model.settingsProject = $0 })
    }

    private var settings: SettingsStore { model.settings }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: selectionBinding) {
                    Section("Pinned") {
                        ForEach(settings.pinned) { p in
                            ProjectListRow(config: p, model: model).tag(p.id)
                        }
                        .onMove { settings.movePinned(from: $0, to: $1) }
                        if settings.pinned.isEmpty {
                            Text("Pin a project to keep it at the top.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    if !added.isEmpty {
                        Section("Added") {
                            ForEach(added) { p in
                                ProjectListRow(config: p, model: model).tag(p.id)
                            }
                        }
                    }
                    Section("Recent") {
                        ForEach(recent) { p in
                            ProjectListRow(config: p, model: model).tag(p.id)
                        }
                    }
                }
                .listStyle(.sidebar)
                Divider()
                HStack {
                    Button {
                        addProject()
                    } label: { Image(systemName: "plus") }
                        .help("Add a project folder")
                    Button {
                        if let id = selection { settings.value.projects.removeAll { $0.id == id }; selection = nil }
                    } label: { Image(systemName: "minus") }
                        .disabled(selection == nil)
                        .help("Forget this project")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(width: 230)

            Divider()

            if let id = selection, settings.project(id) != nil {
                ProjectDetail(id: id, model: model)
                    .id(id)
            } else {
                ProjectRootsView(model: model)
            }
        }
    }

    private var added: [ProjectConfig] {
        settings.value.projects.filter { $0.added && !$0.pinned }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var recent: [ProjectConfig] {
        settings.value.projects.filter { !$0.pinned && !$0.added }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.setPinned(url.path, true)
        selection = url.path
    }
}

private struct ProjectListRow: View {
    let config: ProjectConfig
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            ProjectIcon(project: ProjectDisplay(id: config.id, name: config.name, path: config.path,
                                                config: config, worktrees: [], looseRuns: []),
                        model: model, size: 16)
            Text(config.name)
                .lineLimit(1)
                .foregroundStyle(config.hidden ? .tertiary : .primary)
            Spacer()
            if config.hidden {
                Image(systemName: "eye.slash").foregroundStyle(.tertiary).font(.caption)
            }
            Button {
                model.settings.setPinned(config.id, !config.pinned)
            } label: {
                Image(systemName: config.pinned ? "pin.fill" : "pin")
                    .foregroundStyle(config.pinned ? .primary : .tertiary)
            }
            .buttonStyle(.borderless)
            .help(config.pinned ? "Unpin" : "Pin to top")
        }
    }
}

private struct ProjectDetail: View {
    let id: String
    let model: AppModel
    @State private var newName = ""
    @State private var newCommand = ""

    private var settings: SettingsStore { model.settings }
    private var config: ProjectConfig { settings.project(id) ?? ProjectConfig(id: id) }

    private func binding<T>(_ keyPath: WritableKeyPath<ProjectConfig, T>) -> Binding<T> {
        Binding(get: { config[keyPath: keyPath] }, set: { v in settings.update(id) { $0[keyPath: keyPath] = v } })
    }

    var body: some View {
        let packageScripts = model.catalog.packageScripts(in: id)
        let favorites = config.favoriteScripts ?? ["dev"]
        Form {
            Section {
                TextField("Name", text: Binding(get: { config.displayName ?? "" },
                                                set: { v in settings.update(id) { $0.displayName = v.isEmpty ? nil : v } }),
                          prompt: Text(config.folderName))
                LabeledContent("Folder") {
                    HStack {
                        Text((id as NSString).abbreviatingWithTildeInPath)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Button("Reveal") { ProcessControl.revealInFinder(id) }.controlSize(.small)
                    }
                }
                Toggle("Pinned to top", isOn: Binding(get: { config.pinned }, set: { settings.setPinned(id, $0) }))
                Toggle("Always in the list", isOn: binding(\.added))
                    .disabled(config.pinned)
                Toggle("Hidden from the panel", isOn: binding(\.hidden))
            }

            Section("Icon") {
                HStack(alignment: .center, spacing: 12) {
                    ProjectIcon(project: ProjectDisplay(id: id, name: config.name, path: id, config: config,
                                                        worktrees: [], looseRuns: []),
                                model: model, size: 32)
                    Picker("Source", selection: binding(\.iconMode)) {
                        ForEach(ProjectIconMode.allCases) { Text($0.label).tag($0) }
                    }
                }
                let frameworks = model.catalog.frameworks(in: id)
                if config.iconMode == .framework || config.iconMode == .auto, !frameworks.isEmpty {
                    Picker("Framework", selection: binding(\.frameworkID)) {
                        Text("Automatic (\(frameworks[0].name))").tag(String?.none)
                        ForEach(frameworks, id: \.id) { kind in
                            Label { Text(kind.name) } icon: { KindIcon(kind: kind, size: 16) }
                                .tag(String?.some(kind.id))
                        }
                    }
                }
                if config.iconMode == .auto {
                    Text(ProjectCatalog.findIcon(in: id).map { "Found " + (($0 as NSString).abbreviatingWithTildeInPath) }
                         ?? "No icon found. The framework mark is used instead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.head)
                }
                if config.iconMode == .custom {
                    HStack {
                        Text(config.customIconPath.map { ($0 as NSString).lastPathComponent } ?? "No file")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose…") { chooseIcon() }
                    }
                }
            }

            Section {
                if packageScripts.isEmpty && config.customScripts.isEmpty {
                    Text("No package.json scripts. Add a command below.")
                        .foregroundStyle(.secondary)
                }
                ForEach(config.customScripts) { script in
                    scriptRow(name: script.name, detail: script.command, isFavorite: favorites.contains(script.name),
                              onDelete: { settings.update(id) { $0.customScripts.removeAll { $0.id == script.id } } })
                }
                ForEach(packageScripts) { script in
                    scriptRow(name: script.name, detail: script.detail, isFavorite: favorites.contains(script.name),
                              onDelete: nil)
                }
                HStack(spacing: 6) {
                    TextField("Name", text: $newName, prompt: Text("name"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    TextField("Command", text: $newCommand, prompt: Text("docker compose up"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit(addScript)
                    Button("Add", action: addScript)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty
                                  || newCommand.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Scripts")
            } footer: {
                Text("Starred scripts show as buttons next to pinned projects. Scripts run in the project folder with your login shell.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func addScript() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        let command = newCommand.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !command.isEmpty else { return }
        settings.update(id) { $0.customScripts.append(CustomScript(name: name, command: command)) }
        newName = ""
        newCommand = ""
    }

    private func scriptRow(name: String, detail: String, isFavorite: Bool, onDelete: (() -> Void)?) -> some View {
        HStack(spacing: 8) {
            Button {
                settings.update(id) { c in
                    var favs = c.favoriteScripts ?? ["dev"]
                    if favs.contains(name) { favs.removeAll { $0 == name } } else { favs.append(name) }
                    c.favoriteScripts = favs
                }
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? Color(nsColor: .systemYellow) : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(isFavorite ? "Remove the button" : "Show as a button")
            Text(name).font(.system(.body, design: .monospaced))
            Text(detail)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            if let onDelete {
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
        }
    }

    private func chooseIcon() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .icns]
        panel.directoryURL = URL(fileURLWithPath: id)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.update(id) { $0.customIconPath = url.path; $0.iconMode = .custom }
        model.catalog.invalidateIcons()
    }
}

/// Folders portbar scans for projects. Shown when no project is selected.
private struct ProjectRootsView: View {
    let model: AppModel

    var body: some View {
        let roots = model.settings.value.projectRoots
        Form {
            Section {
                ForEach(roots, id: \.self) { root in
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text((root as NSString).abbreviatingWithTildeInPath)
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                        Text("\(ProjectCatalog.scan([root]).count) projects")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Button(role: .destructive) {
                            model.settings.value.projectRoots.removeAll { $0 == root }
                            model.catalog.invalidateDiscovery()
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Add Folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.prompt = "Add"
                    guard panel.runModal() == .OK, let url = panel.url,
                          !model.settings.value.projectRoots.contains(url.path) else { return }
                    model.settings.value.projectRoots.append(url.path)
                    model.catalog.invalidateDiscovery()
                }
            } header: {
                Text("Project folders")
            } footer: {
                Text("portbar looks one level deep in these folders for projects. Click + in the panel to add one to the list. Select a project on the left to edit it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Hidden

private struct IgnoreSettings: View {
    @Bindable var settings: SettingsStore
    let model: AppModel
    @State private var newPattern = ""

    init(model: AppModel) {
        self.model = model
        self.settings = model.settings
    }

    var body: some View {
        Form {
            Section {
                ForEach(settings.value.ignorePatterns, id: \.self) { pattern in
                    HStack {
                        Text(pattern).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button(role: .destructive) {
                            settings.value.ignorePatterns.removeAll { $0 == pattern }
                            model.refresh()
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Text in the command line, e.g. adb", text: $newPattern)
                        .onSubmit(add)
                    Button("Add", action: add).disabled(newPattern.isEmpty)
                }
            } header: {
                Text("Hidden processes")
            } footer: {
                Text("portbar hides any process whose command line contains one of these strings. Matching is not case-sensitive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            let hidden = settings.value.projects.filter(\.hidden)
            if !hidden.isEmpty {
                Section("Hidden projects") {
                    ForEach(hidden) { p in
                        HStack {
                            Text(p.name)
                            Spacer()
                            Button("Show") { settings.update(p.id) { $0.hidden = false } }
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func add() {
        let p = newPattern.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, !settings.value.ignorePatterns.contains(p) else { return }
        settings.value.ignorePatterns.append(p)
        newPattern = ""
        model.refresh()
    }
}
