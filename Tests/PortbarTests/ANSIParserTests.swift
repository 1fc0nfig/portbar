import SwiftUI
import XCTest
@testable import Portbar

final class ANSIParserTests: XCTestCase {
    func testStripsEscapeCodes() {
        var parser = ANSIParser()
        let line = parser.line("\u{1B}[1m\u{1B}[32mready\u{1B}[0m in 300 ms")
        XCTAssertEqual(line.plain, "ready in 300 ms")
    }

    func testKeepsStyleAcrossLines() {
        var parser = ANSIParser()
        _ = parser.line("\u{1B}[31mfirst")
        let second = parser.line("second")
        XCTAssertNotNil(second.styled.runs.first?.foregroundColor)
    }

    func testCarriageReturnKeepsLastSegment() {
        var parser = ANSIParser()
        XCTAssertEqual(parser.line("10%\r50%\r100%").plain, "100%")
    }

    func testSkipsOSCSequences() {
        var parser = ANSIParser()
        XCTAssertEqual(parser.line("\u{1B}]0;title\u{07}hello").plain, "hello")
    }

    func testLinksURLs() {
        var parser = ANSIParser()
        let line = parser.line("Local: http://localhost:5173/")
        XCTAssertTrue(line.styled.runs.contains { $0.link == URL(string: "http://localhost:5173/") })
    }

    func testErrorFallbackColorsUncoloredLines() {
        var parser = ANSIParser()
        XCTAssertNotNil(parser.line("Error: something broke").styled.runs.first?.foregroundColor)
        XCTAssertNil(parser.line("all good").styled.runs.first?.foregroundColor)
    }
}
