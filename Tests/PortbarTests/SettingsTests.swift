import XCTest
@testable import Portbar

final class SettingsTests: XCTestCase {
    func testEmptyJSONDecodesToDefaults() throws {
        let settings = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings, Settings())
    }

    func testUnknownKeysAreIgnored() throws {
        let json = #"{"refreshInterval": 3, "someFutureKey": true}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.refreshInterval, 3)
    }

    func testRoundTrip() throws {
        var settings = Settings()
        settings.refreshInterval = 5
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: data), settings)
    }
}
