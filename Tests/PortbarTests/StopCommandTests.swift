import Darwin
import XCTest
@testable import Portbar

/// A stop command reaches processes that left the script's process tree, the way a process inside
/// a Docker container does. Each test starts a real shell script.
@MainActor
final class StopCommandTests: XCTestCase {
    private var dir: URL!
    private var runner: ScriptRunner!
    private var started: [ManagedRun] = []

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("portbar-stop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        runner = ScriptRunner()
    }

    override func tearDown() async throws {
        for run in started {
            if run.isRunning { ProcessControl.killTree(run.pid, force: true) }
            runner.dismiss(run)
        }
        if let pid = escapedPid() { kill(pid, SIGKILL) }
        try? FileManager.default.removeItem(at: dir)
    }

    /// Starts a `sleep` that leaves the tree at once (its parent exits, so launchd adopts it),
    /// writes its pid to a file, then waits in the foreground.
    private func startEscaping(name: String = "dev") -> ManagedRun {
        let command = "sh -c 'sleep 300 >/dev/null 2>&1 & echo $! > escaped.pid'; sleep 300"
        let run = runner.start(projectID: dir.path, directory: dir.path, name: name, command: command)
        started.append(run)
        return run
    }

    private func escapedPid() -> pid_t? {
        guard let text = try? String(contentsOf: dir.appendingPathComponent("escaped.pid"), encoding: .utf8) else { return nil }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    private func escaped() async throws -> pid_t {
        await waitUntil { self.escapedPid() != nil }
        let pid = try XCTUnwrap(escapedPid())
        XCTAssertTrue(alive(pid))
        return pid
    }

    /// The bug in issue #3: signals end the script, but the process outside its tree keeps running.
    func testSignalsAloneMissEscapedProcess() async throws {
        let run = startEscaping()
        let pid = try await escaped()
        runner.stop(run)
        await waitUntil { !run.isRunning }
        XCTAssertFalse(run.isRunning)
        XCTAssertTrue(alive(pid), "the escaped process survives Stop without a stop command")
    }

    func testStopCommandStopsEscapedProcess() async throws {
        runner.stopCommand = { _ in "kill $(cat escaped.pid)" }
        let run = startEscaping()
        let pid = try await escaped()
        var result: Bool?
        runner.stop(run) { result = $0 }
        await waitUntil { result != nil }
        XCTAssertEqual(result, true)
        XCTAssertFalse(run.isRunning)
        XCTAssertTrue(run.stoppedByUser)
        XCTAssertFalse(run.failed)
        await waitUntil { !self.alive(pid) }
        XCTAssertFalse(alive(pid))
        let log = run.log.text
        XCTAssertTrue(log.contains("$ kill $(cat escaped.pid)  (stop command)"), log)
        XCTAssertTrue(log.contains("[stop command: exit 0 · success]"), log)
    }

    /// A failed stop command never falls back to signals: the script keeps running and says why.
    func testFailedStopCommandKeepsRunning() async throws {
        runner.stopCommand = { _ in "echo cannot reach the container; exit 3" }
        let run = startEscaping()
        _ = try await escaped()
        var result: Bool?
        runner.stop(run) { result = $0 }
        await waitUntil { result != nil }
        XCTAssertEqual(result, false)
        XCTAssertTrue(run.isRunning)
        XCTAssertTrue(alive(run.pid))
        XCTAssertFalse(run.stopping)
        XCTAssertEqual(run.stopFailure, "Stop command failed: exit 3")
        XCTAssertFalse(run.stoppedByUser)
        let log = run.log.text
        XCTAssertTrue(log.contains("cannot reach the container"), log)
        XCTAssertTrue(log.contains("[stop command failed: exit 3."), log)

        // Force Kill still ends it.
        runner.stop(run, force: true)
        await waitUntil { !run.isRunning }
        XCTAssertFalse(run.isRunning)
    }

    /// Restart waits for the stop command and the old run to end, and a failed stop cancels the start.
    func testRestartWaitsForStopCommand() async throws {
        runner.stopCommand = { _ in "sleep 1; kill $(cat escaped.pid)" }
        let run = startEscaping()
        let pid = try await escaped()
        runner.restart(run)
        XCTAssertTrue(run.stopping)
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertNil(runner.runs.first { $0.id != run.id }, "no new run while the stop command runs")
        await waitUntil { self.runner.runs.contains { $0.id != run.id && $0.isRunning } }
        let next = try XCTUnwrap(runner.runs.first { $0.id != run.id })
        started.append(next)
        XCTAssertFalse(alive(pid), "the old escaped process ended before the new run started")
        XCTAssertFalse(runner.runs.contains { $0.id == run.id })
    }

    func testFailedStopCancelsRestart() async throws {
        runner.stopCommand = { _ in "exit 1" }
        let run = startEscaping()
        _ = try await escaped()
        runner.restart(run)
        await waitUntil { run.stopFailure != nil }
        try? await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertTrue(run.isRunning)
        XCTAssertEqual(runner.runs.count(where: { $0.projectID == dir.path }), 1)
        XCTAssertTrue(run.log.text.contains("[restart cancelled: the old run still runs]"))
    }

    /// Force Kill while the stop command hangs ends both, and counts as a stop, not a failure.
    func testForceKillDuringStopCommand() async throws {
        runner.stopCommand = { _ in "sleep 30" }
        let run = startEscaping()
        _ = try await escaped()
        var results: [Bool] = []
        runner.stop(run) { results.append($0) }
        XCTAssertTrue(run.stopping)
        runner.stop(run, force: true)
        await waitUntil { !run.isRunning && !run.stopping }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(run.isRunning)
        XCTAssertNil(run.stopFailure)
        XCTAssertTrue(run.stoppedByUser)
        XCTAssertFalse(run.failed)
        XCTAssertEqual(results, [true])
        XCTAssertTrue(run.log.text.contains("[stop command ended by Force Kill]"), run.log.text)
    }

    /// The script exits while its stop command still runs (`up` ends during `down`): Restart waits for both.
    func testRestartWaitsWhenScriptEndsDuringStopCommand() async throws {
        runner.stopCommand = { _ in "kill $(cat escaped.pid); sleep 1.5; touch down.done" }
        let command = "sh -c 'sleep 300 >/dev/null 2>&1 & echo $! > escaped.pid'; while kill -0 $(cat escaped.pid) 2>/dev/null; do sleep 0.1; done"
        let run = runner.start(projectID: dir.path, directory: dir.path, name: "up", command: command)
        started.append(run)
        _ = try await escaped()
        runner.restart(run)
        await waitUntil { !run.isRunning }
        XCTAssertFalse(run.isRunning)
        XCTAssertTrue(run.stopping, "the stop command still runs after the script ended")
        XCTAssertNil(runner.runs.first { $0.id != run.id }, "no new run before the stop command ends")
        await waitUntil { self.runner.runs.contains { $0.id != run.id } }
        let next = try XCTUnwrap(runner.runs.first { $0.id != run.id })
        started.append(next)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("down.done").path))
    }

    func testStopCommandTrimsAndDecodes() throws {
        XCTAssertNil(CustomScript(name: "a", command: "x", stopCommand: "  ").stop)
        XCTAssertEqual(CustomScript(name: "a", command: "x", stopCommand: " sail stop ").stop, "sail stop")
        // Scripts saved before stop commands existed still load.
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"dev","command":"sail up"}"#
        let script = try JSONDecoder().decode(CustomScript.self, from: Data(old.utf8))
        XCTAssertNil(script.stopCommand)
    }
}
