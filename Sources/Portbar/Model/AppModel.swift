import AppKit
import Foundation
import Observation
import ServiceManagement
import SwiftUI

/// A project as the panel shows it: live services, plus pinned state and script runs.
@MainActor
struct ProjectDisplay: Identifiable {
    let id: String
    let name: String
    let path: String?
    let config: ProjectConfig?
    var worktrees: [WorktreeGroup]
    /// Script runs with no service of their own yet: booting, one-shot scripts, finished runs.
    var looseRuns: [ManagedRun]
    /// Services you stopped from the panel. They stay until you run them again or dismiss them.
    var stopped: [StoppedEntry] = []

    var pinned: Bool { config?.pinned ?? false }
    var isOther: Bool { path == nil }
    var services: [Service] { worktrees.flatMap(\.services) }
    var isRunning: Bool { !services.isEmpty || looseRuns.contains { $0.isRunning } }
    var hasIssue: Bool { services.contains { !$0.issues.isEmpty } || looseRuns.contains { $0.failed } }
    var hasSevereIssue: Bool { services.contains { $0.issues.contains(where: \.isSevere) } || looseRuns.contains { $0.failed } }
}

/// A service you stopped from portbar. It keeps its row, so you can run it again.
struct StoppedEntry: Identifiable {
    let id = UUID()
    let projectID: String
    let kind: ServiceKind
    let command: String?
    let directory: String?
    let ports: [UInt16]
    let stoppedAt = Date()
    /// The run it belonged to, for logs.
    let run: ManagedRun?
    /// It ended on its own. False when the user stopped it.
    var exited = false

    /// `bun run dev` → `dev`, so a re-run lines up with the project's script buttons.
    var scriptName: String {
        guard let command else { return kind.name }
        let words = command.split(separator: " ").map(String.init)
        if words.count == 3, ["npm", "bun", "pnpm", "yarn"].contains(words[0]), words[1] == "run" { return words[2] }
        return kind.name
    }
}

enum SettingsTab: String, Hashable {
    case general, panel, projects, hidden
}

enum DotState: Equatable {
    case running, warning, critical, stopped, empty
    var isIssue: Bool { self == .warning || self == .critical }
}

@MainActor
@Observable
final class AppModel {
    let settings = SettingsStore()
    let runner = ScriptRunner()
    let catalog = ProjectCatalog()

    private(set) var snapshot = Snapshot()
    /// Services the user just stopped, by id. Hidden while they shut down.
    @ObservationIgnored private var stopping: [String: Date] = [:]
    /// Services that just exited on their own, shown dimmed for a moment. See `apply`.
    @ObservationIgnored private var ghosts: [String: (service: Service, since: Date)] = [:]
    private static let exitGrace: TimeInterval = 3
    /// CPU percent samples per service id, oldest first.
    private(set) var cpuHistory: [String: [Double]] = [:]
    /// Memory samples in bytes per service id, oldest first.
    private(set) var memoryHistory: [String: [Double]] = [:]
    var stopped: [StoppedEntry] = []

    /// Which Settings tab and project to show. Right-click menus set these, then open Settings.
    var settingsTab: SettingsTab = .general
    var settingsProject: String?
    @ObservationIgnored var openSettingsAction: OpenSettingsAction?

    var isPanelOpen = false {
        didSet {
            guard isPanelOpen != oldValue else { return }
            if isPanelOpen { refresh(probe: true) }
            reschedule()
        }
    }

    var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet {
            do {
                if launchAtLogin { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("portbar: launch at login failed: \(error)")
            }
        }
    }

    @ObservationIgnored private let graph = ServiceGraph()
    @ObservationIgnored private let probe = HealthProbe()
    @ObservationIgnored private let queue = DispatchQueue(label: "portbar.scan", qos: .utility)
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var unresponsive: Set<String> = []
    @ObservationIgnored private var scanning = false
    @ObservationIgnored private var scheduledInterval: TimeInterval = 0

    init() {
        DispatchQueue.global(qos: .utility).async { _ = LoginEnvironment.shared }
        refresh(probe: false)
        reschedule()
    }

    // MARK: Display

    var projects: [ProjectDisplay] {
        let s = settings.value
        let hidden = Set(s.projects.filter(\.hidden).map(\.id))
        var live: [String: ProjectGroup] = [:]
        for p in snapshot.projects where !hidden.contains(p.id) { live[p.id] = p }

        func display(_ id: String, group: ProjectGroup?, config: ProjectConfig?) -> ProjectDisplay {
            ProjectDisplay(
                id: id,
                name: config?.name ?? group?.name ?? (id as NSString).lastPathComponent,
                path: group?.path ?? (id.hasPrefix("~") ? nil : id),
                config: config,
                worktrees: group?.worktrees ?? [],
                looseRuns: []
            )
        }

        var result: [ProjectDisplay] = []
        for config in s.projects where config.pinned && !config.hidden {
            result.append(display(config.id, group: live.removeValue(forKey: config.id), config: config))
        }
        // Running and added projects, alphabetical. Processes outside repos go last.
        let configs = Dictionary(s.projects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var middle: [ProjectDisplay] = live.values
            .filter { !($0.isOther && !s.showOther) }
            .map { display($0.id, group: $0, config: configs[$0.id]) }
        for config in s.projects where config.added && !config.pinned && !config.hidden && live[config.id] == nil {
            middle.append(display(config.id, group: nil, config: config))
        }
        let sort = s.projectSort
        middle.sort { a, b in
            if a.isOther != b.isOther { return !a.isOther }
            if sort == .modified, let pa = a.path, let pb = b.path {
                let da = catalog.lastModified(pa), db = catalog.lastModified(pb)
                if da != db { return da > db }
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        result += middle

        // Stopped services keep a row in their project.
        for entry in stopped {
            if let i = result.firstIndex(where: { $0.id == entry.projectID }) {
                result[i].stopped.append(entry)
            } else if !hidden.contains(entry.projectID) {
                var d = display(entry.projectID, group: nil, config: settings.project(entry.projectID))
                d.stopped = [entry]
                result.append(d)
            }
        }

        // Attach script runs that no service claims.
        let services = result.flatMap(\.services)
        let stoppedRuns = Set(stopped.compactMap { $0.run?.id })
        for run in runner.runs where !stoppedRuns.contains(run.id) {
            let claimed = services.contains { s in
                (run.isRunning || s.exiting) && (s.root.pid == run.pid || s.ancestorPids.contains(run.pid))
            }
            guard !claimed else { continue }
            if let i = result.firstIndex(where: { $0.id == run.projectID }) {
                result[i].looseRuns.append(run)
            } else {
                var d = display(run.projectID, group: nil, config: settings.project(run.projectID))
                d.looseRuns = [run]
                result.append(d)
            }
        }
        return result
    }

    func run(for service: Service) -> ManagedRun? {
        runner.runs.first { $0.isRunning && ($0.pid == service.root.pid || service.ancestorPids.contains($0.pid)) }
    }

    var visibleServiceCount: Int { projects.reduce(0) { $0 + $1.services.count } }
    var hasSevereIssue: Bool { projects.contains(where: \.hasSevereIssue) }
    var issueCount: Int { projects.flatMap(\.services).filter { !$0.issues.isEmpty }.count }

    /// Four menu bar dots: pinned projects first, then other running projects.
    var dots: [DotState] {
        let all = projects
        func state(_ p: ProjectDisplay) -> DotState {
            p.hasSevereIssue ? .critical : p.hasIssue ? .warning : p.isRunning ? .running : .stopped
        }
        let pinned = all.filter(\.pinned).prefix(4)
        let others = all.filter { !$0.pinned && $0.isRunning }.prefix(4 - pinned.count)
        let slotted = Array(pinned) + Array(others)
        var slots = slotted.map(state)
        // An issue that has no dot of its own still shows on the last dot.
        let slottedIDs = Set(slotted.map(\.id))
        let unslotted = all.filter { !slottedIDs.contains($0.id) }
        if let last = slots.indices.last {
            if unslotted.contains(where: \.hasSevereIssue) { slots[last] = .critical }
            else if unslotted.contains(where: \.hasIssue), slots[last] != .critical { slots[last] = .warning }
        }
        while slots.count < 4 { slots.append(.empty) }
        return slots
    }

    // MARK: Scanning

    private func reschedule() {
        let interval: TimeInterval = isPanelOpen ? max(1, settings.value.refreshInterval) : 5
        guard interval != scheduledInterval || timer == nil else { return }
        scheduledInterval = interval
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(probe: self?.isPanelOpen ?? false) }
        }
        timer?.tolerance = interval / 4
    }

    func refresh(probe shouldProbe: Bool = false) {
        guard !scanning else { return }
        scanning = true
        let known = unresponsive
        let ignore = settings.value.ignorePatterns
        let hours = settings.value.forgottenAfterHours
        let forgottenAfter: TimeInterval? = hours > 0 ? hours * 3600 : nil
        let graph = graph
        queue.async {
            let snap = graph.build(unresponsive: known, ignore: ignore, forgottenAfter: forgottenAfter)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.apply(snap)
                    self.scanning = false
                    if shouldProbe { self.runProbe(snap) }
                }
            }
        }
    }

    private func apply(_ fresh: Snapshot) {
        let now = Date()
        stopping = stopping.filter { now.timeIntervalSince($0.value) < 10 }
        let live = fresh.removing(stopping.keys)

        // A service that exits on its own stays as a dimmed ghost for a few seconds. If nothing
        // replaces it (a restart, a hot reload), it turns into an Exited row in the same place.
        let liveIDs = Set(live.services.map(\.id))
        for s in snapshot.services where !liveIDs.contains(s.id) && !s.exiting && stopping[s.id] == nil && s.location != nil {
            var ghost = s
            ghost.exiting = true
            ghost.cpuPercent = 0
            ghost.issues = []
            ghosts[s.id] = (ghost, now)
        }
        ghosts = ghosts.filter { id, _ in !liveIDs.contains(id) && stopping[id] == nil }
        var exited: [StoppedEntry] = []
        for (id, ghost) in ghosts {
            let s = ghost.service
            let replaced = live.services.contains { $0.kind == s.kind && $0.directory == s.directory }
            if replaced { ghosts[id] = nil; continue }
            guard now.timeIntervalSince(ghost.since) >= Self.exitGrace else { continue }
            ghosts[id] = nil
            let run = runner.runs.first { $0.pid == s.root.pid || s.ancestorPids.contains($0.pid) }
            let again = s.rerun
            guard run != nil || again != nil,
                  !stopped.contains(where: { $0.kind == s.kind && $0.directory == s.directory }) else { continue }
            exited.append(StoppedEntry(
                projectID: s.location?.repoRoot ?? "~other", kind: s.kind,
                command: run?.command ?? again?.command, directory: run?.directory ?? again?.directory ?? s.directory,
                ports: s.ports, run: run, exited: true))
        }
        let snap = ghosts.isEmpty ? live
            : Snapshot(projects: ServiceGraph.group(live.services + ghosts.values.map(\.service)),
                       date: live.date, pending: live.pending)

        // Animate rows in and out only while the panel shows them.
        let update = {
            self.snapshot = snap
            self.stopped += exited
            // A stopped row goes away when the same service runs again, from here or from a terminal.
            self.stopped.removeAll { entry in
                snap.services.contains { $0.kind == entry.kind && $0.directory == entry.directory && $0.startTime > entry.stoppedAt }
            }
        }
        if isPanelOpen { withAnimation(.smooth(duration: 0.3), update) } else { update() }
        if snap.pending || !ghosts.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { self.refresh() }
        }
        var cpu: [String: [Double]] = [:]
        var memory: [String: [Double]] = [:]
        func push(_ value: Double, _ old: [Double]?) -> [Double] {
            var samples = old ?? []
            samples.append(value)
            if samples.count > 60 { samples.removeFirst(samples.count - 60) }
            return samples
        }
        for s in snap.services where s.exiting {
            cpu[s.id] = cpuHistory[s.id]
            memory[s.id] = memoryHistory[s.id]
        }
        for s in snap.services where !s.exiting {
            cpu[s.id] = push(s.cpuPercent, cpuHistory[s.id])
            memory[s.id] = push(Double(s.memoryBytes), memoryHistory[s.id])
        }
        cpuHistory = cpu
        memoryHistory = memory

        settings.remember(snap.projects.compactMap(\.path))
        reschedule()
    }

    private func runProbe(_ snap: Snapshot) {
        let targets = snap.services
            .filter { $0.kind.speaksHTTP }
            .flatMap { s in s.ports.prefix(2).map { (key: "\(s.root.pid):\($0)", port: $0) } }
        guard !targets.isEmpty else { return }
        Task {
            let result = await probe.probe(targets)
            if result != unresponsive {
                unresponsive = result
                refresh()
            }
        }
    }

    // MARK: Actions

    /// Opens Settings at a tab, optionally with one project selected.
    func showSettings(_ tab: SettingsTab, project: String? = nil) {
        if let project {
            settings.update(project) { _ in }   // make sure it is in the list
        }
        settingsTab = tab
        settingsProject = tab == .projects ? project : settingsProject
        openSettingsAction?()
        NSApp.activate(ignoringOtherApps: true)
    }

    func stop(_ service: Service, includeLaunchers: Bool = false, force: Bool = false) {
        let run = run(for: service)
        let again = service.rerun
        // Swap the row for its stopped row at once, and keep it out while the process shuts down.
        stopping[service.id] = Date()
        withAnimation(.smooth(duration: 0.3)) {
            snapshot = snapshot.removing(stopping.keys)
            stopped.append(StoppedEntry(
            projectID: service.location?.repoRoot ?? "~other",
            kind: service.kind,
            command: run?.command ?? again?.command,
            directory: run?.directory ?? again?.directory ?? service.directory,
            ports: service.ports,
            run: run
        ))
        }
        if let run, includeLaunchers {
            runner.stop(run, force: force)
        } else {
            ProcessControl.stop(service, includeLaunchers: includeLaunchers, force: force)
        }
        refreshSoon()
    }

    func stopAllDetached() {
        for s in snapshot.services where s.issues.contains(.detached) || s.issues.contains(.forgotten) { stop(s, includeLaunchers: true) }
    }

    func start(_ script: ProjectScript, projectID: String, directory: String) {
        runner.start(projectID: projectID, directory: directory, name: script.name, command: script.command)
        refreshSoon()
    }

    /// Starts a stopped service again, inside portbar.
    func runAgain(_ entry: StoppedEntry) {
        withAnimation(.smooth(duration: 0.3)) { stopped.removeAll { $0.id == entry.id } }
        guard let command = entry.command, let directory = entry.directory else { return }
        runner.start(projectID: entry.projectID, directory: directory, name: entry.scriptName, command: command)
        refreshSoon()
    }

    func dismiss(_ entry: StoppedEntry) {
        withAnimation(.smooth(duration: 0.3)) { stopped.removeAll { $0.id == entry.id } }
        if let run = entry.run, !run.isRunning { runner.dismiss(run) }
    }

    /// Stops the service and starts it again inside portbar, so its logs show up here.
    func restart(_ service: Service) {
        if let run = run(for: service) {
            runner.restart(run)
            refreshSoon()
            return
        }
        stop(service, includeLaunchers: true)
        guard let entry = stopped.last else { return }
        // Give the old process time to free its port.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.runAgain(entry) }
    }

    func stop(_ run: ManagedRun) {
        runner.stop(run)
        refreshSoon()
    }

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refresh() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.refresh() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.refresh() }
    }

    func appWillTerminate() {
        if settings.value.stopScriptsOnQuit { runner.stopAll() }
    }
}
