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
    let id = UUID()
    let projectID: String
    let directory: String
    let name: String
    let command: String
    let started = Date()
    let log = LogBuffer()
    fileprivate(set) var pid: pid_t = 0
    /// The exit status, or the signal number when a signal ended the process.
    fileprivate(set) var exitCode: Int32?
    /// The signal that ended the process, if any.
    fileprivate(set) var signal: Int32?
    fileprivate(set) var stoppedByUser = false

    var isRunning: Bool { exitCode == nil }
    var failed: Bool { (exitCode ?? 0) != 0 && !stoppedByUser }
    var exit: ExitStatus? { exitCode.map { ExitStatus(code: $0, signal: signal) } }

    init(projectID: String, directory: String, name: String, command: String) {
        self.projectID = projectID
        self.directory = directory
        self.name = name
        self.command = command
    }
}

@MainActor
@Observable
final class ScriptRunner {
    private(set) var runs: [ManagedRun] = []
    @ObservationIgnored private var processes: [UUID: Process] = [:]

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

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [weak run] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            let chunk = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { MainActor.assumeIsolated { run?.log.append(chunk) } }
        }
        process.terminationHandler = { [weak self, weak run] p in
            let code = p.terminationStatus
            let signal = p.terminationReason == .uncaughtSignal ? code : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let run else { return }
                    let exit = ExitStatus(code: code, signal: signal)
                    run.log.flush()
                    run.log.appendNote("[\(exit.long)]")
                    run.signal = signal
                    run.exitCode = code
                    self?.processes[run.id] = nil
                }
            }
        }

        run.log.appendNote("$ \(command)")
        do {
            try process.run()
            run.pid = process.processIdentifier
            processes[run.id] = process
        } catch {
            run.log.appendNote("Could not start: \(error.localizedDescription)")
            run.exitCode = -1
        }
        runs.append(run)
        return run
    }

    func stop(_ run: ManagedRun, force: Bool = false) {
        guard run.isRunning, run.pid > 0 else { return }
        run.stoppedByUser = true
        ProcessControl.killTree(run.pid, force: force)
    }

    func restart(_ run: ManagedRun) {
        let (p, d, n, c) = (run.projectID, run.directory, run.name, run.command)
        stop(run)
        dismiss(run)
        // Give the old server time to free its port.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            self.start(projectID: p, directory: d, name: n, command: c)
        }
    }

    func dismiss(_ run: ManagedRun) {
        runs.removeAll { $0.id == run.id }
    }

    func stopAll() {
        for run in runs where run.isRunning { ProcessControl.killTree(run.pid, force: false, wait: false) }
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
