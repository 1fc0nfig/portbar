import XCTest
@testable import Portbar

final class ExitStatusTests: XCTestCase {
    func testSuccess() {
        let exit = ExitStatus(code: 0, signal: nil)
        XCTAssertTrue(exit.isSuccess)
        XCTAssertEqual(exit.short, "exit 0")
        XCTAssertEqual(exit.long, "exit 0 · success")
    }

    func testPlainFailure() {
        let exit = ExitStatus(code: 3, signal: nil)
        XCTAssertFalse(exit.isSuccess)
        XCTAssertEqual(exit.long, "exit 3")
    }

    func testCommandNotFound() {
        XCTAssertEqual(ExitStatus(code: 127, signal: nil).long, "exit 127 · command not found")
    }

    func testSignalFromProcess() {
        let exit = ExitStatus(code: 15, signal: 15)
        XCTAssertEqual(exit.short, "SIGTERM")
        XCTAssertEqual(exit.long, "terminated (SIGTERM)")
    }

    func testSignalReportedByShell() {
        let exit = ExitStatus(code: 130, signal: nil)
        XCTAssertEqual(exit.signalNumber, 2)
        XCTAssertEqual(exit.long, "exit 130 · interrupted (SIGINT)")
    }
}
