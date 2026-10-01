import AppKit
import SwiftUI

/// Search over the project folders, to add projects to the panel list.
struct AddProjectView: View {
    let model: AppModel
    @State private var query = ""
    @FocusState private var focused: Bool
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let roots = model.settings.value.projectRoots
        let all = model.catalog.sorted(model.catalog.discover(roots: roots), by: model.settings.value.projectSort) {
            model.settings.project($0)?.name ?? ($0 as NSString).lastPathComponent
        }
        let matches = query.isEmpty ? all : all.filter {
            ($0 as NSString).lastPathComponent.localizedCaseInsensitiveContains(query)
        }
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                TextField("Add a project", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .onSubmit { if let first = matches.first { toggle(first) } }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Divider().opacity(0.6)

            if roots.isEmpty {
                hint("Add a project folder, such as ~/dev, to find your projects.")
            } else if matches.isEmpty {
                hint(query.isEmpty ? "No projects found in your project folders." : "No match for “\(query)”.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(matches, id: \.self) { path in
                            AddProjectRow(path: path, model: model) { toggle(path) }
                        }
                    }
                    .padding(4)
                }
                .frame(height: min(CGFloat(matches.count) * 30 + 8, 320))
            }

            Divider().opacity(0.6)
            HStack {
                Button("Add Folder…", action: addFolder)
                Spacer()
                SortMenu(settings: model.settings)
                Spacer()
                Button("Project Folders…") {
                    model.settingsProject = nil
                    model.showSettings(.projects)
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .frame(width: 320)
        .onAppear { focused = true }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(18)
    }

    private func toggle(_ path: String) {
        let config = model.settings.project(path)
        if config?.pinned == true { return }
        if config?.added == true { model.settings.removeFromList(path) } else { model.settings.add(path) }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add to List"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.settings.add(url.path)
    }
}

private struct AddProjectRow: View {
    let path: String
    let model: AppModel
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let config = model.settings.project(path)
        let display = ProjectDisplay(id: path, name: config?.name ?? (path as NSString).lastPathComponent,
                                     path: path, config: config, worktrees: [], looseRuns: [])
        Button(action: action) {
            HStack(spacing: 8) {
                ProjectIcon(project: display, model: model, size: 16)
                Text(display.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text(((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                if config?.pinned == true {
                    Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                } else if config?.added == true {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                } else if hovering {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.06 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Name or Last Modified. Shared by the add picker and the panel menu.
struct SortMenu: View {
    let settings: SettingsStore

    var body: some View {
        Menu {
            Picker("Sort Projects By", selection: Binding(get: { settings.value.projectSort },
                                                          set: { settings.value.projectSort = $0 })) {
                ForEach(ProjectSort.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Label(settings.value.projectSort.label, systemImage: "arrow.up.arrow.down")
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Sort projects")
    }
}
