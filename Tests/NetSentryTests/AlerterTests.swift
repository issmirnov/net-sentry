import XCTest
@testable import NetSentry

final class AlerterTests: XCTestCase {
    func testDownFiresAllEnabledChannels() {
        var calls: [SpawnCall] = []
        let alerter = Alerter(config: Config.defaults) { calls.append($0) }
        alerter.fire(.down)
        let bins = calls.map(\.executable)
        XCTAssertTrue(bins.contains("/usr/bin/say"))
        XCTAssertEqual(bins.filter { $0 == "/usr/bin/osascript" }.count, 2,
                       "modal + banner are both osascript")
    }

    func testUpFiresOnlyBannerByDefault() {
        var calls: [SpawnCall] = []
        let alerter = Alerter(config: Config.defaults) { calls.append($0) }
        alerter.fire(.up)
        let bins = calls.map(\.executable)
        XCTAssertEqual(bins.filter { $0 == "/usr/bin/say" }.count, 0,
                       "speech text_up is empty by default")
        XCTAssertEqual(bins.filter { $0 == "/usr/bin/osascript" }.count, 1,
                       "only banner has non-empty text_up by default")
    }

    func testDisabledChannelDoesNotFire() {
        var c = Config.defaults
        c.notifiers.speech.enabled = false
        var calls: [SpawnCall] = []
        let alerter = Alerter(config: c) { calls.append($0) }
        alerter.fire(.down)
        XCTAssertEqual(calls.filter { $0.executable == "/usr/bin/say" }.count, 0)
    }

    func testEmptyTextSkipsChannel() {
        var c = Config.defaults
        c.notifiers.modal.textDown = ""
        var calls: [SpawnCall] = []
        let alerter = Alerter(config: c) { calls.append($0) }
        alerter.fire(.down)
        let modalCalls = calls.filter {
            $0.executable == "/usr/bin/osascript" &&
            $0.args.joined(separator: " ").contains("display dialog")
        }
        XCTAssertEqual(modalCalls.count, 0)
    }

    func testSpeechVoiceFlag() {
        var calls: [SpawnCall] = []
        let alerter = Alerter(config: Config.defaults) { calls.append($0) }
        alerter.fire(.down)
        let say = calls.first { $0.executable == "/usr/bin/say" }
        XCTAssertNotNil(say)
        XCTAssertEqual(say?.args, ["-v", "Samantha", "Internet is down"])
    }

    func testModalCarriesIconAndTimeout() {
        var calls: [SpawnCall] = []
        let alerter = Alerter(config: Config.defaults) { calls.append($0) }
        alerter.fire(.down)
        let modal = calls.first {
            $0.executable == "/usr/bin/osascript" &&
            $0.args.joined(separator: " ").contains("display dialog")
        }
        XCTAssertNotNil(modal)
        let script = modal!.args.last!
        XCTAssertTrue(script.contains("with icon stop"))
        XCTAssertTrue(script.contains("giving up after 30"))
        XCTAssertTrue(script.contains("Internet is down"))
    }

    func testAppleScriptEscapesBackslashAndQuote() {
        // Backslash before quote — order matters; if quote ran first we'd
        // double-escape the backslash we introduced.
        XCTAssertEqual(Alerter.escapeForAppleScript(#"path\with\backslash"#), #"path\\with\\backslash"#)
        XCTAssertEqual(Alerter.escapeForAppleScript(#"say "hi""#), #"say \"hi\""#)
        XCTAssertEqual(Alerter.escapeForAppleScript(#"\"both\""#), #"\\\"both\\\""#)
    }
}
