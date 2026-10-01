import XCTest
@testable import Portbar

final class ClassifierTests: XCTestCase {
    private func process(_ exe: String, _ args: [String]) -> RawProcess {
        RawProcess(pid: 100, ppid: 1, name: (exe as NSString).lastPathComponent, executable: exe, args: args,
                   cwd: "/tmp", startTime: Date(), cpuTimeNs: 0, rssBytes: 0, hasTTY: false,
                   fromPortbar: false, listenPorts: [])
    }

    func testVite() {
        let p = process("/usr/local/bin/node", ["node", "/app/node_modules/vite/bin/vite.js", "--host"])
        XCTAssertEqual(Classifier.classify(p).kind.id, "vite")
    }

    func testNext() {
        let p = process("/usr/local/bin/node", ["node", "/app/node_modules/.bin/next", "dev"])
        XCTAssertEqual(Classifier.classify(p).kind.id, "next")
    }

    func testPackageManagerIsWrapper() {
        let p = process("/opt/homebrew/bin/bun", ["bun", "run", "dev"])
        XCTAssertEqual(Classifier.classify(p).role, .wrapper)
    }
}
