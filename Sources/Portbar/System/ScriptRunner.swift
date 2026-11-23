import Darwin
import Foundation
import Observation

/// One log line: plain text for filter and copy, styled text for display.
struct LogLine {
    let plain: String
    let styled: AttributedString
}

/// Output of one run. Keeps the last 5000 lines and turns ANSI colors into styled text.
@MainActor
@Observable
final class LogBuffer {
    private(set) var lines: [LogLine] = []
    @ObservationIgnored private var partial = ""
    @ObservationIgnored private var parser = ANSIParser()
    private static let limit = 5000

    func append(_ chunk: String) {
        let text = partial + chunk
        var parts = text.components(separatedBy: "\n")
        partial = parts.removeLast()
        for part in parts { lines.append(parser.line(part)) }
        if lines.count > Self.limit { lines.removeFirst(lines.count - Self.limit) }
    }

    /// A line portbar writes itself, such as the command or the exit code.
    func appendNote(_ text: String) {
        flush()
        var styled = AttributedString(text)
        styled.foregroundColor = .secondary
        lines.append(LogLine(plain: text, styled: styled))
    }

    func flush() {
        if !partial.isEmpty { lines.append(parser.line(partial)); partial = "" }
    }

    var text: String { lines.map(\.plain).joined(separator: "\n") }
}

/// A script portbar started and owns.
@MainActor
@Observable
final class ManagedRun: Identifiable {
    let id: UUID
    let projectID: String
    let directory: String
    let name: String
    let command: String
    let started: Date
    let log = LogBuffer()
    fileprivate(set) var pid: pid_t = 0
    /// The exit status, or the signal number when a signal ended the process.
    fileprivate(set) var exitCode: Int32?
    /// The signal that ended the process, if any.
    fileprivate(set) var signal: Int32?
    fileprivate(set) var stoppedByUser = false
    /// When the run ended. Finished runs leave the panel some time after this.
    fileprivate(set) var ended: Date?
    /// Started by an earlier portbar. When it ends, its exit status is unknown.
    fileprivate(set) var adopted = false
    /// The script's stop command runs now.
    fileprivate(set) var stopping = false
    /// Why the last stop command did not stop the script. Cleared by the next stop.
    fileprivate(set) var stopFailure: String?
    /// Stop signalled a docker CLI with no stop command, so container processes may still run.
    fileprivate(set) var reachedDocker = false
    /// Force Kill ran while a stop command ran. Its end is then no failure.
    fileprivate var forced = false
    @ObservationIgnored fileprivate var tail: LogTail?
    @ObservationIgnored fileprivate var exitWatch: DispatchSourceProcess?

    var isRunning: Bool { exitCode == nil }
    var failed: Bool { (exitCode ?? 0) != 0 && !stoppedByUser }
    var exit: ExitStatus? { adopted ? nil : exitCode.map { ExitStatus(code: $0, signal: signal) } }

    init(id: UUID = UUID(), projectID: String, directory: String, name: String, command: String, started: Date = Date()) {
        self.id = id
        self.projectID = projectID
        self.directory = directory
        self.name = name
        self.command = command
        self.started = started
    }
}

/// What portbar writes next to each run's log, so a later portbar can pick the run up again.
struct RunRecord: Codable {
    let id: UUID
    let projectID: String
    let directory: String
    let name: String
    let command: String
    let started: Date
    let pid: pid_t
    /// The process start time in seconds. A reused pid has a different one.
    let processStart: Int
}

/// Run logs and records live in ~/Library/Logs/portbar. Scripts write their output to the log file
/// themselves, so the output survives a portbar restart.
enum RunFiles {
    static let directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/portbar", isDirectory: true)

    static func log(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).log") }
    static func record(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }

    static func save(_ record: RunRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: Self.record(record.id), options: .atomic)
    }

    static func records() -> [RunRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap {
            guard let data = try? Data(contentsOf: $0) else { return nil }
            return try? JSONDecoder().decode(RunRecord.self, from: data)
        }
    }

    static func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: log(id))
        try? FileManager.default.removeItem(at: record(id))
    }

    /// Log files with no record, left behind when portbar crashed during a start.
    static func removeOrphans(keeping ids: Set<UUID>) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "log" {
            if let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !ids.contains(id) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// The start time of a live process in seconds, or nil when the pid is gone.
    static func processStart(_ pid: pid_t) -> Int? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Int(info.pbi_start_tvsec)
    }
}

/// Follows a growing log file and feeds new output to a log buffer.
@MainActor
final class LogTail {
    private let handle: FileHandle
    private let source: DispatchSourceFileSystemObject
    private var offset: UInt64 = 0
    /// Past this size the file starts over. The buffer keeps the recent lines anyway.
    private static let maxFileSize: UInt64 = 32 << 20
    /// How much of an existing file to read when portbar picks a run up again.
    private static let backlog: UInt64 = 512 << 10

    init?(url: URL, into log: LogBuffer, fromEnd: Bool = false) {
        guard let handle = try? FileHandle(forUpdating: url) else { return nil }
        self.handle = handle
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: handle.fileDescriptor, eventMask: [.extend, .write], queue: .main)
        if fromEnd, let size = try? handle.seekToEnd(), size > Self.backlog {
            offset = size - Self.backlog
            // Skip the first line, it is likely cut.
            if let data = read(), let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
                log.append(String(decoding: data[data.index(after: newline)...], as: UTF8.self))
            }
        }
        source.setEventHandler { [weak self, weak log] in
            MainActor.assumeIsolated { if let log { self?.drain(into: log) } }
        }
        source.resume()
        drain(into: log)
    }

    /// Reads all output written so far.
    func drain(into log: LogBuffer) {
        guard let data = read() else { return }
        log.append(String(decoding: data, as: UTF8.self))
        if offset > Self.maxFileSize {
            // Scripts open the file in append mode, so they keep writing at the new end.
            try? handle.truncate(atOffset: 0)
            offset = 0
        }
    }

    private func read() -> Data? {
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        offset += UInt64(data.count)
        return data
    }

    func close() {
        source.cancel()
        try? handle.close()
    }
}

@MainActor
@Observable
final class ScriptRunner {
    private(set) var runs: [ManagedRun] = []
    @ObservationIgnored private var processes: [UUID: Process] = [:]
    /// Stop commands that run now, by run id.
    @ObservationIgnored private var stopProcesses: [UUID: Process] = [:]
    /// Called once when a run ends (true), or when its stop command fails (false).
    /// Stop commands portbar ended because they ran past `stopTimeout`.
    @ObservationIgnored private var timedOut: Set<UUID> = []
    @ObservationIgnored private var stopWaiters: [UUID: [(Bool) -> Void]] = [:]
    /// The stop command of a run, read at stop time, so an edit in Settings applies to runs that already run.
    @ObservationIgnored var stopCommand: (ManagedRun) -> String? = { _ in nil }
    static let dockerHint = "Processes inside Docker can keep running after Stop. "
        + "Add a stop command to this script in Project Settings → Scripts."
    /// How long a stop command may run before portbar ends it and reports a failure.
    static let stopTimeout: TimeInterval = 60

    init() {
        try? FileManager.default.createDirectory(at: RunFiles.directory, withIntermediateDirectories: true)
        adoptEarlierRuns()
    }

    func runs(for projectID: String) -> [ManagedRun] { runs.filter { $0.projectID == projectID } }

    func activeRun(projectID: String, directory: String, name: String) -> ManagedRun? {
        runs.first { $0.projectID == projectID && $0.directory == directory && $0.name == name && $0.isRunning }
    }

    func run(for pid: pid_t) -> ManagedRun? { runs.first { $0.pid == pid && $0.isRunning } }

    @discardableResult
    func start(projectID: String, directory: String, name: String, command: String) -> ManagedRun {
        if let existing = activeRun(projectID: projectID, directory: directory, name: name) { return existing }

        let run = ManagedRun(projectID: projectID, directory: directory, name: name, command: command)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: LoginEnvironment.shell)
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var env = LoginEnvironment.shared
        env["PORTBAR"] = "1"
        env["FORCE_COLOR"] = "1"         // picocolors, chalk, and most JS tools
        env["CLICOLOR_FORCE"] = "1"      // BSD tools, Go and Rust tools
        env["PY_COLORS"] = "1"
        process.environment = env

        // Append mode, so the reader can truncate a large file and the script keeps writing.
        let path = RunFiles.log(run.id).path
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        let output = fd >= 0 ? FileHandle(fileDescriptor: fd, closeOnDealloc: true) : FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice

        process.terminationHandler = { [weak self, weak run] p in
            let code = p.terminationStatus
            let signal = p.terminationReason == .uncaughtSignal ? code : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let run else { return }
                    self?.finish(run) { run.signal = signal; run.exitCode = code }
                    self?.processes[run.id] = nil
                }
            }
        }

        run.log.appendNote("$ \(command)")
        do {
            try process.run()
            run.pid = process.processIdentifier
            processes[run.id] = process
            RunFiles.save(RunRecord(id: run.id, projectID: projectID, directory: directory, name: name,
                                    command: command, started: run.started, pid: run.pid,
                                    processStart: RunFiles.processStart(run.pid) ?? 0))
            run.tail = LogTail(url: RunFiles.log(run.id), into: run.log)
        } catch {
            run.log.appendNote("Could not start: \(error.localizedDescription)")
            run.exitCode = -1
            run.ended = Date()
        }
        if fd >= 0 { try? output.close() }
        runs.append(run)
        return run
    }

    /// Picks up scripts an earlier portbar started that still run. Removes files of runs that ended.
    private func adoptEarlierRuns() {
        let records = RunFiles.records()
        RunFiles.removeOrphans(keeping: Set(records.map(\.id)))
        for record in records {
            guard record.pid > 0, RunFiles.processStart(record.pid) == record.processStart else {
                RunFiles.remove(record.id)
                continue
            }
            let run = ManagedRun(id: record.id, projectID: record.projectID, directory: record.directory,
                                 name: record.name, command: record.command, started: record.started)
            run.pid = record.pid
            run.adopted = true
            run.log.appendNote("$ \(record.command)  (started by an earlier portbar)")
            run.tail = LogTail(url: RunFiles.log(record.id), into: run.log, fromEnd: true)

            // Not our child, so watch for its exit with kqueue.
            let watch = DispatchSource.makeProcessSource(identifier: record.pid, eventMask: .exit, queue: .main)
            watch.setEventHandler { [weak self, weak run] in
                MainActor.assumeIsolated {
                    guard let run else { return }
                    self?.finish(run) { run.exitCode = 0 }
                }
            }
            watch.resume()
            run.exitWatch = watch
            runs.append(run)
            // It may have ended before the watch started.
            if kill(record.pid, 0) != 0 { finish(run) { run.exitCode = 0 } }
        }
    }

    /// Reads the last output, then marks the run as ended.
    private func finish(_ run: ManagedRun, _ setExit: () -> Void) {
        guard run.isRunning else { return }
        run.tail?.drain(into: run.log)
        // A stop command still writes to the log. Its end closes the tail.
        if stopProcesses[run.id] == nil {
            run.tail?.close()
            run.tail = nil
        }
        run.exitWatch?.cancel()
        run.exitWatch = nil
        run.log.flush()
        setExit()
        run.ended = Date()
        run.log.appendNote(run.exit.map { "[\($0.long)]" } ?? "[ended]")
        // Restart waits for the stop command too, so `docker compose down` finishes before the next `up`.
        if stopProcesses[run.id] == nil { resolveWaiters(run, true) }
    }

    private func resolveWaiters(_ run: ManagedRun, _ ended: Bool) {
        let waiters = stopWaiters.removeValue(forKey: run.id) ?? []
        for waiter in waiters { waiter(ended) }
    }

    /// Stops the run. With a stop command, runs it first and signals the process tree only when it
    /// succeeds. A failed stop command leaves the script running and says why in the log.
    /// `then` gets true when the run has ended, false when the stop command failed.
    func stop(_ run: ManagedRun, force: Bool = false, then: ((Bool) -> Void)? = nil) {
        guard run.isRunning, run.pid > 0 else { then?(!run.isRunning); return }
        if let then { stopWaiters[run.id, default: []].append(then) }
        if !force, let command = stopCommand(run) {
            runStopCommand(command, for: run)
            return
        }
        // Force Kill ends a stop command that hangs, too.
        if let stopper = stopProcesses[run.id] {
            run.forced = true
            ProcessControl.killTree(stopper.processIdentifier, force: true)
        }
        run.stoppedByUser = true
        let tree = [run.pid] + ProcessControl.descendants(of: run.pid)
        ProcessControl.killTree(run.pid, force: force)
        if tree.contains(where: { ProcessControl.isDockerClient($0) }) {
            run.reachedDocker = true
            run.log.appendNote(Self.dockerHint)
        }
    }

    private func runStopCommand(_ command: String, for run: ManagedRun) {
        guard !run.stopping else { return }
        run.stopping = true
        run.stopFailure = nil
        run.stoppedByUser = true
        run.log.appendNote("$ \(command)  (stop command)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: LoginEnvironment.shell)
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: run.directory)
        var env = LoginEnvironment.shared
        env["PORTBAR"] = "1"
        process.environment = env
        // Same log file as the script, so the output shows in its log window.
        let fd = open(RunFiles.log(run.id).path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        let output = fd >= 0 ? FileHandle(fileDescriptor: fd, closeOnDealloc: true) : FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice

        let id = run.id
        process.terminationHandler = { [weak self, weak run] p in
            let status = ExitStatus(code: p.terminationStatus,
                                    signal: p.terminationReason == .uncaughtSignal ? p.terminationStatus : nil)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Clean up by id, also when the run was dismissed in the meantime.
                    self.stopProcesses[id] = nil
                    let timedOut = self.timedOut.remove(id) != nil
                    if let run { self.stopEnded(run, status: status, timedOut: timedOut) }
                }
            }
        }
        do {
            try process.run()
            stopProcesses[run.id] = process
            let pid = process.processIdentifier
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.stopTimeout) { [weak self] in
                guard let self, self.stopProcesses[id] === process, process.isRunning else { return }
                self.timedOut.insert(id)
                ProcessControl.killTree(pid, force: false)
            }
        } catch {
            run.stopping = false
            run.stoppedByUser = false
            run.stopFailure = "Stop command could not start"
            run.log.appendNote("[stop command could not start: \(error.localizedDescription)]")
            resolveWaiters(run, false)
        }
        if fd >= 0 { try? output.close() }
    }

    private func stopEnded(_ run: ManagedRun, status: ExitStatus, timedOut: Bool) {
        run.stopping = false
        run.tail?.drain(into: run.log)
        run.log.flush()
        if run.forced {
            run.forced = false
            run.log.appendNote("[stop command ended by Force Kill]")
            if !run.isRunning { run.tail?.close(); run.tail = nil; resolveWaiters(run, true) }
            return
        }
        if !run.isRunning {
            // The script ended while the stop command ran. Waiters held on until now.
            run.tail?.close()
            run.tail = nil
            run.log.appendNote("[stop command: \(status.long)]")
            resolveWaiters(run, true)
            return
        }
        if status.isSuccess && !timedOut {
            run.log.appendNote("[stop command: \(status.long)]")
            // The script's own processes on this Mac, such as the docker CLI, end the usual way.
            ProcessControl.killTree(run.pid, force: false)
            return
        }
        let reason = timedOut ? "timed out after \(Int(Self.stopTimeout)) s" : status.long
        run.stopFailure = "Stop command failed: \(reason)"
        run.stoppedByUser = false
        run.log.appendNote("[stop command failed: \(reason). The script still runs. "
                           + "Stop again to retry, or use Force Kill.]")
        resolveWaiters(run, false)
    }

    /// Stops the run, waits until it has ended, then starts it again. A failed stop command cancels the start.
    func restart(_ run: ManagedRun) {
        let (p, d, n, c) = (run.projectID, run.directory, run.name, run.command)
        stop(run) { [weak self, weak run] ended in
            guard let self else { return }
            guard ended else {
                run?.log.appendNote("[restart cancelled: the old run still runs]")
                return
            }
            let warn = run?.reachedDocker ?? false
            if let run { self.dismiss(run) }
            // The tree gets the signal at once, but children can hold the port a moment longer.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let next = self.start(projectID: p, directory: d, name: n, command: c)
                // The old log is gone, so the new one keeps the warning.
                if warn { next.log.appendNote(Self.dockerHint) }
            }
        }
    }

    func dismiss(_ run: ManagedRun) {
        run.tail?.close()
        run.tail = nil
        run.exitWatch?.cancel()
        run.exitWatch = nil
        RunFiles.remove(run.id)
        runs.removeAll { $0.id == run.id }
    }

    /// On quit: runs the stop commands, waits up to 15 seconds for them in total, then signals every tree.
    func stopAll() {
        let live = runs.filter(\.isRunning)
        var stoppers: [Process] = []
        for run in live {
            guard let command = stopCommand(run) else { continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: LoginEnvironment.shell)
            process.arguments = ["-c", command]
            process.currentDirectoryURL = URL(fileURLWithPath: run.directory)
            process.environment = LoginEnvironment.shared
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            if (try? process.run()) != nil { stoppers.append(process) }
        }
        let deadline = Date().addingTimeInterval(15)
        while stoppers.contains(where: \.isRunning) && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        for run in live { ProcessControl.killTree(run.pid, force: false, wait: false) }
    }
}

/// How a script ended, in words. Shells report a child that a signal ended as 128 + the signal.
struct ExitStatus: Equatable {
    let code: Int32
    let signal: Int32?

    /// The signal behind the status, from the process itself or from the shell's 128 + n.
    var signalNumber: Int32? {
        if let signal { return signal }
        return (129...159).contains(code) ? code - 128 : nil
    }

    var isSuccess: Bool { code == 0 && signal == nil }

    /// For a badge: "exit 0", "exit 1", "SIGTERM".
    var short: String {
        if let signal { return Self.name(signal) }
        return "exit \(code)"
    }

    /// For logs and tooltips: "exit 143 · terminated (SIGTERM)".
    var long: String {
        if let signal { return "\(Self.meaning(signal)) (\(Self.name(signal)))" }
        var text = "exit \(code)"
        if let n = signalNumber { text += " · \(Self.meaning(n)) (\(Self.name(n)))" }
        else if code == 127 { text += " · command not found" }
        else if code == 126 { text += " · not executable" }
        else if code == 0 { text += " · success" }
        return text
    }

    static func name(_ n: Int32) -> String {
        let names: [Int32: String] = [1: "SIGHUP", 2: "SIGINT", 3: "SIGQUIT", 4: "SIGILL", 6: "SIGABRT",
                                      9: "SIGKILL", 10: "SIGBUS", 11: "SIGSEGV", 13: "SIGPIPE", 15: "SIGTERM"]
        return names[n] ?? "signal \(n)"
    }

    private static func meaning(_ n: Int32) -> String {
        switch n {
        case 2: return "interrupted"
        case 9: return "killed"
        case 15: return "terminated"
        case 6: return "aborted"
        case 10, 11: return "crashed"
        case 1: return "hung up"
        case 13: return "broken pipe"
        default: return "ended by a signal"
        }
    }
}

/// The environment of the user's login shell, so scripts find bun, node, nvm and friends.
enum LoginEnvironment {
    static let shell: String = {
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell { return String(cString: sh) }
        return "/bin/zsh"
    }()

    static let shared: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        if let login = capture() { env.merge(login) { _, new in new } }
        // Fallback paths in case the shell profile could not load.
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.bun/bin",
                     NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/.cargo/bin"]
        let path = (env["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init)
        env["PATH"] = (path + extra.filter { !path.contains($0) }).joined(separator: ":")
        env.removeValue(forKey: "TERM_PROGRAM")
        return env
    }()

    /// Runs `$SHELL -lic 'env -0'` with a 5 second limit.
    private static func capture() -> [String: String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", "env -0"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate(); return nil }

        let data = out.fileHandleForReading.readDataToEndOfFile()
        var env: [String: String] = [:]
        for entry in data.split(separator: 0) {
            let s = String(decoding: entry, as: UTF8.self)
            guard let eq = s.firstIndex(of: "=") else { continue }
            env[String(s[..<eq])] = String(s[s.index(after: eq)...])
        }
        return env.isEmpty ? nil : env
    }
}
