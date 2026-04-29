import XCTest
@testable import NetSentry

final class ConfigDefaultsTests: XCTestCase {
    func testDefaultsHaveSaneValues() {
        let c = Config.defaults

        XCTAssertEqual(c.debounce.seconds, 2.0)

        XCTAssertTrue(c.notifiers.speech.enabled)
        XCTAssertEqual(c.notifiers.speech.voice, "Samantha")
        XCTAssertEqual(c.notifiers.speech.textDown, "Internet is down")
        XCTAssertEqual(c.notifiers.speech.textUp, "")

        XCTAssertTrue(c.notifiers.modal.enabled)
        XCTAssertEqual(c.notifiers.modal.icon, "stop")
        XCTAssertEqual(c.notifiers.modal.timeoutSeconds, 30)
        XCTAssertEqual(c.notifiers.modal.textDown, "Internet is down")
        XCTAssertEqual(c.notifiers.modal.textUp, "")

        XCTAssertTrue(c.notifiers.banner.enabled)
        XCTAssertEqual(c.notifiers.banner.title, "Net Sentry")
        XCTAssertEqual(c.notifiers.banner.textDown, "Internet is down")
        XCTAssertEqual(c.notifiers.banner.textUp, "Internet is back")
    }
}
