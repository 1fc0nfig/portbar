import Foundation
import Observation

enum MenuBarStyle: String, Codable, CaseIterable, Identifiable {
    case dotGrid, icon, iconCount
    var id: String { rawValue }
    var label: String {
        switch self {
        case .dotGrid: "Dot grid"
        case .icon: "Icon"
        case .iconCount: "Icon and count"
        }
    }
}

enum ProjectSort: String, Codable, CaseIterable, Identifiable {
    case name, modified
    var id: String { rawValue }
    var label: String { self == .name ? "Name" : "Last Modified" }
}

enum Density: String, Codable, CaseIterable, Identifiable {
    case compact, regular
    var id: String { rawValue }
    var label: String { self == .compact ? "Compact" : "Regular" }
}

enum ProjectIconMode: String, Codable, CaseIterable, Identifiable {
    /// Favicon or app icon found in the repository.
    case auto
    /// A file the user picked.
    case custom
    /// The brand mark of the main service (Next.js, Vite).
    case framework
    case none
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: "Find in project"
        case .custom: "Custom file"
        case .framework: "Framework"
        case .none: "None"
        }
    }
}

struct CustomScript: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var command: String
}

/// Per-repository preferences. Keyed by the main checkout path.
struct ProjectConfig: Codable, Identifiable, Hashable {
    let id: String
    var displayName: String?
    var pinned = false
    var hidden = false
    var iconMode: ProjectIconMode = .auto
    var customIconPath: String?
    /// Framework chosen for the icon. `nil` picks the first one detected.
    var frameworkID: String?
    /// Scripts shown as one-click buttons. `nil` means "dev" when the project has it.
    var favoriteScripts: [String]?
    var customScripts: [CustomScript] = []
    var lastSeen = Date()
    /// Always listed in the panel, also when stopped. Pinned projects are listed anyway.
    var added = false

    init(id: String) { self.id = id }

    // Tolerate missing keys, so new fields do not wipe saved projects.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        iconMode = try c.decodeIfPresent(ProjectIconMode.self, forKey: .iconMode) ?? .auto
        customIconPath = try c.decodeIfPresent(String.self, forKey: .customIconPath)
        frameworkID = try c.decodeIfPresent(String.self, forKey: .frameworkID)
        favoriteScripts = try c.decodeIfPresent([String].self, forKey: .favoriteScripts)
        customScripts = try c.decodeIfPresent([CustomScript].self, forKey: .customScripts) ?? []
        lastSeen = try c.decodeIfPresent(Date.self, forKey: .lastSeen) ?? Date()
        added = try c.decodeIfPresent(Bool.self, forKey: .added) ?? false
    }

    /// Shown in the panel even when nothing runs.
    var isListed: Bool { (pinned || added) && !hidden }

    var path: String { id }
    var folderName: String { (id as NSString).lastPathComponent }
    var name: String { displayName?.isEmpty == false ? displayName! : folderName }
}

struct Settings: Codable, Equatable {
    var menuBarStyle: MenuBarStyle = .dotGrid
    var density: Density = .regular
    var showSparkline = true
    var showMemory = false
    var showUptime = true
    var showCommand = true
    var showOther = true
    var showProjectIcons = true
    var refreshInterval: Double = 2
    /// Order of unpinned projects in the panel and in the add picker. Pinned projects keep the user's order.
    var projectSort: ProjectSort = .name
    var panelWidth: Double = Settings.defaultWidth
    var panelMaxHeight: Double = Settings.defaultMaxHeight
    var stopScriptsOnQuit = true
    /// Hours after which a detached process counts as forgotten (red). 0 turns this off.
    var forgottenAfterHours: Double = 12
    /// Folders portbar scans for projects you can add to the panel.
    var projectRoots: [String] = Settings.defaultRoots
    /// Processes whose command line contains one of these strings are hidden.
    var ignorePatterns: [String] = []
    /// Pinned projects first, in the user's order, then everything else seen before.
    var projects: [ProjectConfig] = []

    init() {}

    // Tolerate missing keys, so new settings do not wipe old ones.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings.defaults
        menuBarStyle = try c.decodeIfPresent(MenuBarStyle.self, forKey: .menuBarStyle) ?? d.menuBarStyle
        density = try c.decodeIfPresent(Density.self, forKey: .density) ?? d.density
        showSparkline = try c.decodeIfPresent(Bool.self, forKey: .showSparkline) ?? d.showSparkline
        showMemory = try c.decodeIfPresent(Bool.self, forKey: .showMemory) ?? d.showMemory
        showUptime = try c.decodeIfPresent(Bool.self, forKey: .showUptime) ?? d.showUptime
        showCommand = try c.decodeIfPresent(Bool.self, forKey: .showCommand) ?? d.showCommand
        showOther = try c.decodeIfPresent(Bool.self, forKey: .showOther) ?? d.showOther
        showProjectIcons = try c.decodeIfPresent(Bool.self, forKey: .showProjectIcons) ?? d.showProjectIcons
        refreshInterval = try c.decodeIfPresent(Double.self, forKey: .refreshInterval) ?? d.refreshInterval
        projectSort = try c.decodeIfPresent(ProjectSort.self, forKey: .projectSort) ?? d.projectSort
        panelWidth = try c.decodeIfPresent(Double.self, forKey: .panelWidth) ?? d.panelWidth
        panelMaxHeight = try c.decodeIfPresent(Double.self, forKey: .panelMaxHeight) ?? d.panelMaxHeight
        stopScriptsOnQuit = try c.decodeIfPresent(Bool.self, forKey: .stopScriptsOnQuit) ?? d.stopScriptsOnQuit
        forgottenAfterHours = try c.decodeIfPresent(Double.self, forKey: .forgottenAfterHours) ?? d.forgottenAfterHours
        ignorePatterns = try c.decodeIfPresent([String].self, forKey: .ignorePatterns) ?? d.ignorePatterns
        projectRoots = Settings.uniqueFolders(try c.decodeIfPresent([String].self, forKey: .projectRoots) ?? d.projectRoots)
        projects = try c.decodeIfPresent([ProjectConfig].self, forKey: .projects) ?? d.projects
    }

    static let defaults = Settings()

    static let defaultWidth: Double = 440
    static let defaultMaxHeight: Double = 600
    static let widthRange: ClosedRange<Double> = 360...760
    static let heightRange: ClosedRange<Double> = 280...1000

    /// Common code folders that exist on this Mac.
    static var defaultRoots: [String] {
        let home = NSHomeDirectory()
        return uniqueFolders(["dev", "Developer", "code", "projects", "src", "repos", "work", "GitHub"]
            .map { (home as NSString).appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0) })
    }

    /// Drops folders that are the same on disk: `~/projects` and `~/Projects` on a case-insensitive volume.
    static func uniqueFolders(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { path in
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            let key = (try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier)
                .map { "\($0)" } ?? path.lowercased()
            return seen.insert(key).inserted
        }
    }
}

/// Loads and saves `Settings` as JSON in UserDefaults.
@MainActor
@Observable
final class SettingsStore {
    var value: Settings {
        didSet { if value != oldValue { save() } }
    }

    private static let key = "settings.v1"

    init() {
        // Settings from before the rename live under the old bundle id. Copy them over once.
        let legacy = UserDefaults(suiteName: "com.cernymatyas.portrunner")?.data(forKey: Self.key)
        if UserDefaults.standard.data(forKey: Self.key) == nil, let legacy {
            UserDefaults.standard.set(legacy, forKey: Self.key)
        }
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(Settings.self, from: data) {
            value = decoded
        } else {
            value = Settings()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    func project(_ id: String) -> ProjectConfig? { value.projects.first { $0.id == id } }

    func update(_ id: String, _ change: (inout ProjectConfig) -> Void) {
        if let i = value.projects.firstIndex(where: { $0.id == id }) {
            change(&value.projects[i])
        } else {
            var config = ProjectConfig(id: id)
            change(&config)
            value.projects.append(config)
        }
    }

    /// Pinned projects in user order.
    var pinned: [ProjectConfig] { value.projects.filter(\.pinned) }

    func setPinned(_ id: String, _ pinned: Bool) {
        update(id) { $0.pinned = pinned }
        // Keep pinned projects at the front, in the order they were pinned.
        let pins = value.projects.filter(\.pinned)
        let rest = value.projects.filter { !$0.pinned }
        value.projects = pins + rest
    }

    func movePinned(from source: IndexSet, to destination: Int) {
        var pins = value.projects.filter(\.pinned)
        pins.move(fromOffsets: source, toOffset: destination)
        value.projects = pins + value.projects.filter { !$0.pinned }
    }

    /// Adds a project to the panel list.
    func add(_ id: String) {
        update(id) { $0.added = true; $0.hidden = false }
    }

    /// Takes a project off the panel list. It still shows while it runs.
    func removeFromList(_ id: String) {
        update(id) { $0.added = false; $0.pinned = false }
    }

    /// Remembers repositories seen running, so they show in Settings.
    func remember(_ ids: [String]) {
        var changed = false
        var projects = value.projects
        let now = Date()
        for id in ids {
            if let i = projects.firstIndex(where: { $0.id == id }) {
                if now.timeIntervalSince(projects[i].lastSeen) > 3600 {
                    projects[i].lastSeen = now
                    changed = true
                }
            } else {
                projects.append(ProjectConfig(id: id))
                changed = true
            }
        }
        if changed { value.projects = projects }
    }
}
