import Darwin
import Foundation

/// Declaration order is display priority: the first issue of a service is the one its row shows.
enum Issue: Hashable, Comparable {
    /// Detached and running for longer than the "forgotten" limit in Settings.
    case forgotten
    /// Sustained high CPU.
    case busy
    /// The port accepts connections but the server does not answer HTTP.
    case unresponsive
    /// The terminal or tool that started it is gone.
    case detached

    var label: String {
        switch self {
        case .forgotten: "Forgotten"
        case .busy: "High CPU"
        case .unresponsive: "Not responding"
        case .detached: "Detached"
        }
    }

    var explanation: String {
        switch self {
        case .forgotten: "The terminal or tool that started this process is gone, and it has run for a long time."
        case .busy: "CPU use has been above 80% for a while."
        case .unresponsive: "The port is open, but the server does not answer HTTP requests."
        case .detached: "The terminal or tool that started this process is gone."
        }
    }

    /// Red instead of orange.
    var isSevere: Bool { self != .detached }
}

/// A group of processes that together do one job, for example `next dev` and its workers.
struct Service: Identifiable {
    let id: String
    let kind: ServiceKind
    let root: RawProcess
    let members: [RawProcess]
    /// Wrapper processes above the root, outermost first (`bun run dev`, `concurrently`).
    let launchers: [RawProcess]
    let ports: [UInt16]
    /// Every process above the root, nearest first. Used to find the script run that started it.
    let ancestorPids: [pid_t]
    let location: GitLocation?
    let directory: String?
    var cpuPercent: Double
    var issues: Set<Issue>
    /// The process is gone. The row stays for a short grace period.
    var exiting = false
    /// Started by a portbar script run whose session ended (portbar restarted). No logs.
    var fromEarlierSession: Bool { ([root] + launchers).contains(where: \.fromPortbar) }

    var memoryBytes: UInt64 { members.reduce(0) { $0 + $1.rssBytes } }
    var startTime: Date { root.startTime }
    var allPids: [pid_t] { members.map(\.pid) }

    /// The command line shown in the row, with long paths reduced to their tool name.
    var command: String { Self.shorten(root.args) }
    var launcherCommand: String? { launchers.first.map { Self.shorten($0.args) } }

    /// Directory relative to the worktree, e.g. `apps/web`.
    var relativeDirectory: String? {
        guard let dir = directory else { return nil }
        guard let root = location?.worktreeRoot else {
            return (dir as NSString).abbreviatingWithTildeInPath
        }
        if dir == root { return nil }
        if dir.hasPrefix(root + "/") { return String(dir.dropFirst(root.count + 1)) }
        return (dir as NSString).abbreviatingWithTildeInPath
    }

    /// The shell command and folder that start this service again: the outermost launcher when there is one.
    var rerun: (command: String, directory: String)? {
        let top = launchers.first ?? root
        guard let dir = top.cwd ?? directory, dir != "/" else { return nil }
        // Node and Bun rewrite argv when they set `process.title`. Such argv cannot be run again.
        if top.args.count <= 1, top.args.first?.contains(" ") ?? true { return nil }
        return (Self.shellQuote(top.args), dir)
    }

    static func shellQuote(_ args: [String]) -> String {
        args.map { a in
            if !a.isEmpty, a.range(of: #"^[A-Za-z0-9_@%+=:,./-]+$"#, options: .regularExpression) != nil { return a }
            return "'" + a.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        }.joined(separator: " ")
    }

    var primaryURL: URL? { ports.first.flatMap { URL(string: "http://localhost:\($0)") } }

    static func shorten(_ args: [String]) -> String {
        var words = args
        if words.count == 1, words[0].contains(" ") { return words[0] }
        // Drop the interpreter when it runs a script: `node /x/node_modules/.bin/next dev` → `next dev`.
        let interpreters: Set = ["node", "bun", "deno", "python", "python3", "ruby"]
        if let first = words.first, interpreters.contains((first as NSString).lastPathComponent),
           words.count > 1 {
            var rest = Array(words.dropFirst())
            if rest.first == "--bun" { rest.removeFirst() }
            if let script = rest.first, script.contains("/") { words = rest }
        }
        return words.map { w in
            if w.hasPrefix("/") || w.hasPrefix("./") {
                if let r = w.range(of: "node_modules/.bin/") { return String(w[r.upperBound...]) }
                if let r = w.range(of: "node_modules/", options: .backwards) {
                    let rest = w[r.upperBound...]
                    return rest.split(separator: "/").first.map(String.init) ?? String(rest)
                }
                return (w as NSString).lastPathComponent
            }
            return w
        }.joined(separator: " ")
    }
}

struct WorktreeGroup: Identifiable {
    let id: String
    let branch: String?
    let isLinked: Bool
    let path: String?
    var services: [Service]
}

struct ProjectGroup: Identifiable {
    let id: String
    let name: String
    let path: String?
    var worktrees: [WorktreeGroup]
    var isOther: Bool { path == nil }
    var services: [Service] { worktrees.flatMap(\.services) }
}

struct Snapshot {
    var projects: [ProjectGroup] = []
    var date = Date()
    /// True when some new services wait for the settle delay. The model scans again soon.
    var pending = false
    var services: [Service] { projects.flatMap(\.services) }
    var issueCount: Int { services.filter { !$0.issues.isEmpty }.count }
    var portCount: Int { services.reduce(0) { $0 + $1.ports.count } }

    /// The same snapshot without the given services. Drops groups that end up empty.
    func removing<S: Sequence>(_ ids: S) -> Snapshot where S.Element == String {
        let ids = Set(ids)
        guard !ids.isEmpty else { return self }
        var copy = self
        copy.projects = projects.compactMap { project in
            var project = project
            project.worktrees = project.worktrees.compactMap { worktree in
                var worktree = worktree
                worktree.services.removeAll { ids.contains($0.id) }
                return worktree.services.isEmpty ? nil : worktree
            }
            return project.worktrees.isEmpty ? nil : project
        }
        return copy
    }
}

/// Turns the raw process table into services. Keeps CPU history between scans, so reuse one instance.
final class ServiceGraph: @unchecked Sendable {  // used only on the scan queue
    private let scanner = ProcessScanner()
    private let git = GitResolver()
    private var previousCPU: [pid_t: (ns: UInt64, at: Date)] = [:]
    private var busyStreak: [String: Int] = [:]
    private var scanCount = 0
    /// When each service id first showed up, so short-lived processes never reach the panel.
    private var firstSeen: [String: Date] = [:]
    /// The last specific kind of each service, so a row does not flip to "Shell" for one scan.
    private var lastKind: [String: ServiceKind] = [:]
    private var launched = false
    private static let settleDelay: TimeInterval = 1.5

    /// Paths that belong to apps and the OS, not to your projects.
    private static let excludedPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/Library/Apple/",
                                           "/sbin/", "/Library/Application Support/"]
    private static let excludedNames: Set = ["claude", "codex", "gitstatusd", "gitstatusd-darwin-arm64",
                                             "Cursor Helper", "Code Helper", "rapportd"]

    func build(unresponsive: Set<String>, ignore: [String] = [], forgottenAfter: TimeInterval? = 12 * 3600) -> Snapshot {
        scanCount += 1
        if scanCount % 30 == 0 { git.invalidate() }

        let now = Date()
        var all = scanner.scan()
        var candidates = Set<pid_t>()
        var classes: [pid_t: Classification] = [:]

        let patterns = ignore.map { $0.lowercased() }.filter { !$0.isEmpty }
        for (pid, p) in all where isCandidate(p) && !Self.isIgnored(p, patterns) {
            candidates.insert(pid)
            all[pid]?.listenPorts = scanner.listenPorts(of: pid)
            classes[pid] = Classifier.classify(all[pid]!)
        }

        func isSignificant(_ pid: pid_t) -> Bool {
            guard let p = all[pid], let c = classes[pid] else { return false }
            if !p.listenPorts.isEmpty { return true }
            return c.role == .service && c.kind.isSpecific
        }

        func ancestors(of pid: pid_t) -> [pid_t] {
            var chain: [pid_t] = []
            var current = all[pid]?.ppid ?? 0
            var guardCount = 0
            while current > 1, let p = all[current], guardCount < 64 {
                chain.append(current)
                current = p.ppid
                guardCount += 1
            }
            return chain
        }

        // 1. Decide the owner (service root) of each significant process.
        var owner: [pid_t: pid_t] = [:]
        func resolveOwner(_ pid: pid_t) -> pid_t {
            if let o = owner[pid] { return o }
            var result = pid
            if let parent = ancestors(of: pid).first(where: isSignificant) {
                let parentOwner = resolveOwner(parent)
                let mine = classes[pid]!.kind
                let theirs = classes[parentOwner]!.kind
                if mine == theirs || !mine.isSpecific { result = parentOwner }
            }
            owner[pid] = result
            return result
        }
        for pid in candidates where isSignificant(pid) { _ = resolveOwner(pid) }

        // 2. Attach helpers (workers, wrappers below a service) to the nearest service above them.
        for pid in candidates where owner[pid] == nil {
            if let parent = ancestors(of: pid).first(where: { owner[$0] != nil }) {
                owner[pid] = owner[parent]
            }
        }

        // 3. Build services.
        var membersByRoot: [pid_t: [RawProcess]] = [:]
        for (pid, root) in owner { if let p = all[pid] { membersByRoot[root, default: []].append(p) } }

        var services: [Service] = []
        var liveCPU: [pid_t: (ns: UInt64, at: Date)] = [:]
        for (rootPid, members) in membersByRoot {
            guard let root = all[rootPid], let cls = classes[rootPid] else { continue }

            // Wrappers above the root, stopping at interactive shells and non-candidates.
            var launchers: [RawProcess] = []
            for a in ancestors(of: rootPid) {
                guard candidates.contains(a), classes[a]?.role == .wrapper, let p = all[a],
                      !Self.isInteractiveShell(p), owner[a] == nil else { break }
                launchers.insert(p, at: 0)
            }

            let ports = Set(members.flatMap(\.listenPorts)).sorted()
            let directory = ([root] + members + launchers.reversed())
                .compactMap(\.cwd).first { $0 != "/" }
                ?? members.flatMap(\.args).first { $0.hasPrefix(NSHomeDirectory() + "/") }
                    .map { Self.projectDirectory(fromPath: $0) }
            let location = directory.flatMap { git.locate($0) }

            var cpuNs: UInt64 = 0
            var prevNs: UInt64 = 0
            var elapsed: TimeInterval = 0
            for m in members {
                cpuNs += m.cpuTimeNs
                liveCPU[m.pid] = (m.cpuTimeNs, now)
                if let prev = previousCPU[m.pid] {
                    prevNs += prev.ns
                    elapsed = max(elapsed, now.timeIntervalSince(prev.at))
                } else {
                    prevNs += m.cpuTimeNs
                }
            }
            let cpu = elapsed > 0 ? Double(cpuNs &- prevNs) / (elapsed * 1e9) * 100 : 0

            let id = "\(rootPid):\(Int(root.startTime.timeIntervalSince1970))"
            var issues = Set<Issue>()

            let top = launchers.first ?? root
            let daemonKinds: Set = ["postgres", "redis", "mongodb", "mysql", "nginx", "ollama", "docker", "emulator", "adb"]
            // Scripts portbar started are not forgotten, even when an earlier portbar session started them.
            let ours = ([root] + launchers).contains(where: \.fromPortbar)
            if top.ppid == 1, !ours, !daemonKinds.contains(cls.kind.id) {
                if let limit = forgottenAfter, now.timeIntervalSince(top.startTime) > limit {
                    issues.insert(.forgotten)
                } else {
                    issues.insert(.detached)
                }
            }

            busyStreak[id] = cpu > 80 ? (busyStreak[id] ?? 0) + 1 : 0
            if (busyStreak[id] ?? 0) >= 3 { issues.insert(.busy) }

            if ports.contains(where: { unresponsive.contains("\(rootPid):\($0)") }) { issues.insert(.unresponsive) }

            var kind = cls.kind
            if kind.isSpecific { lastKind[id] = kind } else if let known = lastKind[id] { kind = known }

            services.append(Service(
                id: id, kind: kind, root: root,
                members: members.sorted { $0.pid < $1.pid },
                launchers: launchers, ports: ports, ancestorPids: ancestors(of: rootPid), location: location,
                directory: directory, cpuPercent: max(0, cpu), issues: issues
            ))
        }
        previousCPU = liveCPU
        busyStreak = busyStreak.filter { key, _ in services.contains { $0.id == key } }

        // Hold back new services until they live through the settle delay. Startup scripts
        // often start and kill helpers in the first second, and those would flash in the list.
        // Services that already run when portbar launches show at once.
        let ids = Set(services.map(\.id))
        firstSeen = firstSeen.filter { ids.contains($0.key) }
        lastKind = lastKind.filter { ids.contains($0.key) }
        for id in ids where firstSeen[id] == nil { firstSeen[id] = launched ? now : .distantPast }
        launched = true
        let settled = services.filter { now.timeIntervalSince(firstSeen[$0.id]!) >= Self.settleDelay }

        return Snapshot(projects: Self.group(settled), date: now, pending: settled.count < services.count)
    }

    private func isCandidate(_ p: RawProcess) -> Bool {
        let exe = p.executable
        if exe.isEmpty { return false }
        if Self.excludedPrefixes.contains(where: exe.hasPrefix) { return false }
        if exe.contains(".app/Contents/"), !exe.contains("/node_modules/") { return false }
        let base = (exe as NSString).lastPathComponent
        if Self.excludedNames.contains(base) || Self.excludedNames.contains(p.name) { return false }
        return true
    }

    private static func isIgnored(_ p: RawProcess, _ patterns: [String]) -> Bool {
        guard !patterns.isEmpty else { return false }
        let haystack = (p.executable + " " + p.args.joined(separator: " ")).lowercased()
        return patterns.contains { haystack.contains($0) }
    }

    private static func isInteractiveShell(_ p: RawProcess) -> Bool {
        guard let first = p.args.first else { return true }
        if first.hasPrefix("-") { return true }   // login shell: "-zsh"
        let base = (first as NSString).lastPathComponent
        let shells: Set = ["sh", "bash", "zsh", "fish", "dash"]
        return shells.contains(base) && !p.args.contains("-c")
    }

    /// `/Users/me/dev/app/node_modules/.bin/next` → `/Users/me/dev/app`.
    private static func projectDirectory(fromPath path: String) -> String {
        if let r = path.range(of: "/node_modules/") { return String(path[..<r.lowerBound]) }
        return (path as NSString).deletingLastPathComponent
    }

    static func group(_ services: [Service]) -> [ProjectGroup] {
        var projects: [String: ProjectGroup] = [:]
        for s in services {
            let projectID = s.location?.repoRoot ?? "~other"
            let worktreeID = s.location?.worktreeRoot ?? "~other"
            var project = projects[projectID] ?? ProjectGroup(
                id: projectID,
                name: s.location?.repoName ?? "Other",
                path: s.location?.repoRoot,
                worktrees: []
            )
            if let i = project.worktrees.firstIndex(where: { $0.id == worktreeID }) {
                project.worktrees[i].services.append(s)
            } else {
                project.worktrees.append(WorktreeGroup(
                    id: worktreeID, branch: s.location?.branch,
                    isLinked: s.location?.isLinkedWorktree ?? false,
                    path: s.location?.worktreeRoot, services: [s]
                ))
            }
            projects[projectID] = project
        }

        func serviceOrder(_ a: Service, _ b: Service) -> Bool {
            switch (a.ports.first, b.ports.first) {
            case let (x?, y?): return x != y ? x < y : a.kind.name < b.kind.name
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.kind.name != b.kind.name ? a.kind.name < b.kind.name : a.root.pid < b.root.pid
            }
        }

        return projects.values.map { p in
            var p = p
            p.worktrees = p.worktrees.map { w in
                var w = w
                w.services.sort(by: serviceOrder)
                return w
            }.sorted { a, b in
                if a.isLinked != b.isLinked { return !a.isLinked }
                return (a.branch ?? "") < (b.branch ?? "")
            }
            return p
        }.sorted { a, b in
            if a.isOther != b.isOther { return !a.isOther }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}
