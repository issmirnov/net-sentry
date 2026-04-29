import XCTest
@testable import NetSentry

final class ConfigLoaderTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("net-sentry-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testMissingFileReturnsDefaults() {
        let path = tempDir.appendingPathComponent("missing.toml").path
        let result = ConfigLoader.load(path: path)
        XCTAssertEqual(result.config, Config.defaults)
        XCTAssertEqual(result.diagnostic, .fileMissing)
    }

    func testMalformedTOMLReturnsDefaults() throws {
        let path = tempDir.appendingPathComponent("bad.toml").path
        try "this is = = not valid toml".write(toFile: path, atomically: true, encoding: .utf8)
        let result = ConfigLoader.load(path: path)
        XCTAssertEqual(result.config, Config.defaults)
        if case .parseError = result.diagnostic { } else {
            XCTFail("expected .parseError, got \(result.diagnostic)")
        }
    }

    func testValidTOMLOverridesDefaults() throws {
        let path = tempDir.appendingPathComponent("good.toml").path
        try """
        [debounce]
        seconds = 5.0

        [notifiers.speech]
        enabled = false
        voice = "Daniel"
        text_down = "Network gone"
        text_up = "Network up"

        [notifiers.modal]
        enabled = true
        icon = "caution"
        timeout_seconds = 60
        text_down = "Modal down"
        text_up = ""

        [notifiers.banner]
        enabled = true
        title = "MyApp"
        text_down = "Banner down"
        text_up = "Banner up"
        """.write(toFile: path, atomically: true, encoding: .utf8)

        let result = ConfigLoader.load(path: path)
        XCTAssertEqual(result.config.debounce.seconds, 5.0)
        XCTAssertFalse(result.config.notifiers.speech.enabled)
        XCTAssertEqual(result.config.notifiers.speech.voice, "Daniel")
        XCTAssertEqual(result.config.notifiers.speech.textDown, "Network gone")
        XCTAssertEqual(result.config.notifiers.speech.textUp, "Network up")
        XCTAssertEqual(result.config.notifiers.modal.icon, "caution")
        XCTAssertEqual(result.config.notifiers.modal.timeoutSeconds, 60)
        XCTAssertEqual(result.config.notifiers.banner.title, "MyApp")
        XCTAssertEqual(result.diagnostic, .ok)
    }

    func testPartialTOMLPreservesDefaultsForMissingKeys() throws {
        let path = tempDir.appendingPathComponent("partial.toml").path
        try """
        [debounce]
        seconds = 7.0
        """.write(toFile: path, atomically: true, encoding: .utf8)

        let result = ConfigLoader.load(path: path)
        XCTAssertEqual(result.config.debounce.seconds, 7.0)
        XCTAssertEqual(result.config.notifiers.speech.voice, Config.defaults.notifiers.speech.voice)
        XCTAssertEqual(result.config.notifiers.modal.timeoutSeconds, Config.defaults.notifiers.modal.timeoutSeconds)
        XCTAssertEqual(result.diagnostic, .ok)
    }
}
