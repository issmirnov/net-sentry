# net-sentry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a tiny macOS daemon that detects internet connectivity loss via NWPathMonitor and alerts the user via voice + modal + notification, configured via TOML.

**Architecture:** SwiftPM package with a `NetSentry` library target (testable components) and a thin `net-sentry-cli` executable wrapper. The pipeline is: `NWPathMonitor → Debouncer (2 s) → StateMachine → Alerter (parallel shell-outs to /usr/bin/say and /usr/bin/osascript)`. All alert behavior is driven by `~/Library/Application Support/net-sentry/config.toml`, with embedded defaults if the file is missing or malformed. Daemon autostarts as a launchd LaunchAgent.

**Tech Stack:** Swift 5.9+, SwiftPM, Apple Network framework (`NWPathMonitor`), [TOMLKit](https://github.com/LebJe/TOMLKit), XCTest, launchd.

**Spec:** `docs/superpowers/specs/2026-04-29-net-sentry-design.md`

---

## Task 1: Project scaffolding

**Files:**
- Create: `Package.swift`
- Create: `.gitignore`
- Create: `README.md`
- Create: `Sources/NetSentry/.gitkeep`
- Create: `Sources/net-sentry-cli/main.swift`
- Create: `Tests/NetSentryTests/.gitkeep`

- [ ] **Step 1: Create `Package.swift`**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "net-sentry",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "net-sentry", targets: ["net-sentry-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
    ],
    targets: [
        .target(
            name: "NetSentry",
            dependencies: [
                .product(name: "TOMLKit", package: "TOMLKit"),
            ]
        ),
        .executableTarget(
            name: "net-sentry-cli",
            dependencies: ["NetSentry"]
        ),
        .testTarget(
            name: "NetSentryTests",
            dependencies: ["NetSentry"]
        ),
    ]
)
```

- [ ] **Step 2: Create `.gitignore`**

```
.build/
.swiftpm/
Package.resolved
.DS_Store
*.xcodeproj/
```

- [ ] **Step 3: Create `README.md`**

```markdown
# net-sentry

Tiny macOS daemon that loudly alerts you when the internet drops — designed for the "I was voice-dictating and didn't notice Wi-Fi died" failure mode.

## Install

    ./install.sh

## Configure

Edit `~/Library/Application Support/net-sentry/config.toml` to change voice, text, channels, or debounce.

## Logs

Tail `~/Library/Logs/net-sentry.{out,err}.log` or open `Console.app`.

## Uninstall

    ./uninstall.sh
```

- [ ] **Step 4: Create placeholder source files so SwiftPM resolves the targets**

`Sources/net-sentry-cli/main.swift`:
```swift
import Foundation

print("net-sentry: starting")
```

Empty placeholder for the library target:
```bash
touch Sources/NetSentry/.gitkeep
touch Tests/NetSentryTests/.gitkeep
```

- [ ] **Step 5: Verify build works**

Run: `swift build`
Expected: succeeds, fetches TOMLKit, produces `.build/debug/net-sentry`. First run takes ~30 s for dep resolution; subsequent runs are sub-second.

- [ ] **Step 6: Verify executable runs**

Run: `.build/debug/net-sentry`
Expected: prints `net-sentry: starting` and exits.

- [ ] **Step 7: Commit**

```bash
git add Package.swift .gitignore README.md Sources Tests
git commit -m "feat: project scaffolding with SwiftPM + TOMLKit"
```

---

## Task 2: Config struct + embedded defaults

**Files:**
- Create: `Sources/NetSentry/Config.swift`
- Create: `Tests/NetSentryTests/ConfigDefaultsTests.swift`

- [ ] **Step 1: Write failing test for default values**

`Tests/NetSentryTests/ConfigDefaultsTests.swift`:
```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ConfigDefaultsTests`
Expected: FAIL — `Config` is undefined.

- [ ] **Step 3: Implement `Config.swift`**

`Sources/NetSentry/Config.swift`:
```swift
import Foundation

public struct Config: Equatable {
    public var debounce: Debounce
    public var notifiers: Notifiers

    public struct Debounce: Equatable {
        public var seconds: Double
    }

    public struct Notifiers: Equatable {
        public var speech: Speech
        public var modal: Modal
        public var banner: Banner
    }

    public struct Speech: Equatable {
        public var enabled: Bool
        public var voice: String
        public var textDown: String
        public var textUp: String
    }

    public struct Modal: Equatable {
        public var enabled: Bool
        public var icon: String
        public var timeoutSeconds: Int
        public var textDown: String
        public var textUp: String
    }

    public struct Banner: Equatable {
        public var enabled: Bool
        public var title: String
        public var textDown: String
        public var textUp: String
    }

    public static let defaults = Config(
        debounce: Debounce(seconds: 2.0),
        notifiers: Notifiers(
            speech: Speech(
                enabled: true,
                voice: "Samantha",
                textDown: "Internet is down",
                textUp: ""
            ),
            modal: Modal(
                enabled: true,
                icon: "stop",
                timeoutSeconds: 30,
                textDown: "Internet is down",
                textUp: ""
            ),
            banner: Banner(
                enabled: true,
                title: "Net Sentry",
                textDown: "Internet is down",
                textUp: "Internet is back"
            )
        )
    )
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ConfigDefaultsTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/NetSentry/Config.swift Tests/NetSentryTests/ConfigDefaultsTests.swift
git commit -m "feat: Config struct with embedded defaults"
```

---

## Task 3: ConfigLoader — TOML parse, fallback behavior

**Files:**
- Create: `Sources/NetSentry/ConfigLoader.swift`
- Create: `Tests/NetSentryTests/ConfigLoaderTests.swift`

- [ ] **Step 1: Write failing tests covering all four load paths**

`Tests/NetSentryTests/ConfigLoaderTests.swift`:
```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ConfigLoaderTests`
Expected: FAIL — `ConfigLoader` is undefined.

- [ ] **Step 3: Implement `ConfigLoader.swift`**

`Sources/NetSentry/ConfigLoader.swift`:
```swift
import Foundation
import TOMLKit

public enum ConfigDiagnostic: Equatable {
    case ok
    case fileMissing
    case parseError(String)
}

public struct ConfigLoadResult: Equatable {
    public let config: Config
    public let diagnostic: ConfigDiagnostic
}

public enum ConfigLoader {
    public static let defaultPath: String = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("net-sentry/config.toml").path
    }()

    public static func load(path: String) -> ConfigLoadResult {
        guard FileManager.default.fileExists(atPath: path) else {
            return ConfigLoadResult(config: .defaults, diagnostic: .fileMissing)
        }
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            return ConfigLoadResult(config: .defaults, diagnostic: .parseError("could not read file"))
        }
        do {
            let table = try TOMLTable(string: raw)
            let merged = merge(defaults: .defaults, with: table)
            return ConfigLoadResult(config: merged, diagnostic: .ok)
        } catch {
            return ConfigLoadResult(config: .defaults, diagnostic: .parseError(String(describing: error)))
        }
    }

    private static func merge(defaults: Config, with t: TOMLTable) -> Config {
        var c = defaults

        if let d = t["debounce"]?.table {
            if let v = d["seconds"]?.double { c.debounce.seconds = v }
            else if let v = d["seconds"]?.int { c.debounce.seconds = Double(v) }
        }

        if let n = t["notifiers"]?.table {
            if let s = n["speech"]?.table {
                if let v = s["enabled"]?.bool      { c.notifiers.speech.enabled  = v }
                if let v = s["voice"]?.string      { c.notifiers.speech.voice    = v }
                if let v = s["text_down"]?.string  { c.notifiers.speech.textDown = v }
                if let v = s["text_up"]?.string    { c.notifiers.speech.textUp   = v }
            }
            if let m = n["modal"]?.table {
                if let v = m["enabled"]?.bool             { c.notifiers.modal.enabled        = v }
                if let v = m["icon"]?.string              { c.notifiers.modal.icon           = v }
                if let v = m["timeout_seconds"]?.int      { c.notifiers.modal.timeoutSeconds = v }
                if let v = m["text_down"]?.string         { c.notifiers.modal.textDown       = v }
                if let v = m["text_up"]?.string           { c.notifiers.modal.textUp         = v }
            }
            if let b = n["banner"]?.table {
                if let v = b["enabled"]?.bool      { c.notifiers.banner.enabled  = v }
                if let v = b["title"]?.string      { c.notifiers.banner.title    = v }
                if let v = b["text_down"]?.string  { c.notifiers.banner.textDown = v }
                if let v = b["text_up"]?.string    { c.notifiers.banner.textUp   = v }
            }
        }
        return c
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ConfigLoaderTests`
Expected: all four tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/NetSentry/ConfigLoader.swift Tests/NetSentryTests/ConfigLoaderTests.swift
git commit -m "feat: TOML config loader with defaults fallback"
```

---

## Task 4: Debouncer

**Files:**
- Create: `Sources/NetSentry/Debouncer.swift`
- Create: `Tests/NetSentryTests/DebouncerTests.swift`

Debouncer accepts a stream of "candidate values" and only invokes a callback if the same value has been seen continuously for the debounce window without a contradicting value arriving. Tests use a 100 ms window for speed.

- [ ] **Step 1: Write failing tests**

`Tests/NetSentryTests/DebouncerTests.swift`:
```swift
import XCTest
@testable import NetSentry

final class DebouncerTests: XCTestCase {
    func testFiresAfterWindowWithStableValue() {
        let exp = expectation(description: "fires")
        var fired: Int?
        let d = Debouncer<Int>(window: .milliseconds(100), queue: .main) { v in
            fired = v
            exp.fulfill()
        }
        d.submit(42)
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(fired, 42)
    }

    func testCancelsOnNewValueWithinWindow() {
        let exp = expectation(description: "fires")
        var fired: Int?
        let d = Debouncer<Int>(window: .milliseconds(150), queue: .main) { v in
            fired = v
            exp.fulfill()
        }
        d.submit(1)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) {
            d.submit(2)
        }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(fired, 2, "should only fire with the latest value")
    }

    func testRapidFlapResultsInSingleFire() {
        let exp = expectation(description: "fires once")
        exp.expectedFulfillmentCount = 1
        exp.assertForOverFulfill = true
        var fireCount = 0
        let d = Debouncer<Int>(window: .milliseconds(100), queue: .main) { _ in
            fireCount += 1
            exp.fulfill()
        }
        for i in 0..<5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(i * 20)) {
                d.submit(i)
            }
        }
        wait(for: [exp], timeout: 2.0)
        XCTAssertEqual(fireCount, 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter DebouncerTests`
Expected: FAIL — `Debouncer` undefined.

- [ ] **Step 3: Implement `Debouncer.swift`**

`Sources/NetSentry/Debouncer.swift`:
```swift
import Foundation

public final class Debouncer<Value> {
    private let window: DispatchTimeInterval
    private let queue: DispatchQueue
    private let callback: (Value) -> Void
    private var pending: DispatchWorkItem?
    private let lock = NSLock()

    public init(window: DispatchTimeInterval, queue: DispatchQueue, callback: @escaping (Value) -> Void) {
        self.window = window
        self.queue = queue
        self.callback = callback
    }

    public func submit(_ value: Value) {
        lock.lock()
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.callback(value)
        }
        pending = item
        lock.unlock()
        queue.asyncAfter(deadline: .now() + window, execute: item)
    }

    public func cancel() {
        lock.lock()
        pending?.cancel()
        pending = nil
        lock.unlock()
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter DebouncerTests`
Expected: all three tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/NetSentry/Debouncer.swift Tests/NetSentryTests/DebouncerTests.swift
git commit -m "feat: generic Debouncer with cancel-and-reschedule"
```

---

## Task 5: StateMachine

**Files:**
- Create: `Sources/NetSentry/StateMachine.swift`
- Create: `Tests/NetSentryTests/StateMachineTests.swift`

StateMachine tracks `online | offline`, fires transitions, suppresses steady-state, seeds without alert at startup.

- [ ] **Step 1: Write failing tests**

`Tests/NetSentryTests/StateMachineTests.swift`:
```swift
import XCTest
@testable import NetSentry

final class StateMachineTests: XCTestCase {
    func testFirstEventSeedsWithoutAlert() {
        var transitions: [Transition] = []
        let sm = StateMachine { transitions.append($0) }
        sm.handle(.online)
        XCTAssertTrue(transitions.isEmpty, "first event should seed silently")
    }

    func testFirstEventOfflineSeedsSilently() {
        var transitions: [Transition] = []
        let sm = StateMachine { transitions.append($0) }
        sm.handle(.offline)
        XCTAssertTrue(transitions.isEmpty)
    }

    func testTransitionFromOnlineToOfflineFiresDown() {
        var transitions: [Transition] = []
        let sm = StateMachine { transitions.append($0) }
        sm.handle(.online)        // seed
        sm.handle(.offline)
        XCTAssertEqual(transitions, [.down])
    }

    func testTransitionFromOfflineToOnlineFiresUp() {
        var transitions: [Transition] = []
        let sm = StateMachine { transitions.append($0) }
        sm.handle(.offline)       // seed
        sm.handle(.online)
        XCTAssertEqual(transitions, [.up])
    }

    func testSteadyStateIsSilent() {
        var transitions: [Transition] = []
        let sm = StateMachine { transitions.append($0) }
        sm.handle(.online)        // seed
        sm.handle(.online)
        sm.handle(.online)
        XCTAssertTrue(transitions.isEmpty)
    }

    func testFlipFlopFiresBothDirections() {
        var transitions: [Transition] = []
        let sm = StateMachine { transitions.append($0) }
        sm.handle(.online)        // seed
        sm.handle(.offline)
        sm.handle(.online)
        sm.handle(.offline)
        XCTAssertEqual(transitions, [.down, .up, .down])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter StateMachineTests`
Expected: FAIL — `StateMachine`, `Transition` undefined.

- [ ] **Step 3: Implement `StateMachine.swift`**

`Sources/NetSentry/StateMachine.swift`:
```swift
import Foundation

public enum LinkState: Equatable {
    case online
    case offline
}

public enum Transition: Equatable {
    case down   // online → offline
    case up     // offline → online
}

public final class StateMachine {
    private var current: LinkState?
    private let onTransition: (Transition) -> Void

    public init(onTransition: @escaping (Transition) -> Void) {
        self.onTransition = onTransition
    }

    public func handle(_ next: LinkState) {
        defer { current = next }
        guard let prev = current else { return }   // first event: seed silently
        guard prev != next else { return }          // steady state: silent
        switch (prev, next) {
        case (.online, .offline): onTransition(.down)
        case (.offline, .online): onTransition(.up)
        default: break
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter StateMachineTests`
Expected: all six tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/NetSentry/StateMachine.swift Tests/NetSentryTests/StateMachineTests.swift
git commit -m "feat: state machine with transition-only alerts"
```

---

## Task 6: Alerter (with mockable subprocess)

**Files:**
- Create: `Sources/NetSentry/Alerter.swift`
- Create: `Tests/NetSentryTests/AlerterTests.swift`

Alerter reads notifier configs and dispatches shell-outs. To make it testable, the subprocess invocation is injected as a closure (`SpawnFn`) — production code passes the real `Process()` runner; tests pass a recorder.

- [ ] **Step 1: Write failing tests**

`Tests/NetSentryTests/AlerterTests.swift`:
```swift
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
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AlerterTests`
Expected: FAIL — `Alerter`, `SpawnCall` undefined.

- [ ] **Step 3: Implement `Alerter.swift`**

`Sources/NetSentry/Alerter.swift`:
```swift
import Foundation

public struct SpawnCall: Equatable {
    public let executable: String
    public let args: [String]
}

public typealias SpawnFn = (SpawnCall) -> Void

public final class Alerter {
    private let config: Config
    private let spawn: SpawnFn

    public init(config: Config, spawn: @escaping SpawnFn = Alerter.realSpawn) {
        self.config = config
        self.spawn = spawn
    }

    public func fire(_ direction: Transition) {
        let isDown = (direction == .down)

        let speech = config.notifiers.speech
        let speechText = isDown ? speech.textDown : speech.textUp
        if speech.enabled && !speechText.isEmpty {
            spawn(SpawnCall(executable: "/usr/bin/say", args: ["-v", speech.voice, speechText]))
        }

        let modal = config.notifiers.modal
        let modalText = isDown ? modal.textDown : modal.textUp
        if modal.enabled && !modalText.isEmpty {
            let escaped = modalText.replacingOccurrences(of: "\"", with: "\\\"")
            let timeoutClause = modal.timeoutSeconds > 0 ? " giving up after \(modal.timeoutSeconds)" : ""
            let script = "display dialog \"\(escaped)\" with icon \(modal.icon) buttons {\"OK\"} default button \"OK\"\(timeoutClause)"
            spawn(SpawnCall(executable: "/usr/bin/osascript", args: ["-e", script]))
        }

        let banner = config.notifiers.banner
        let bannerText = isDown ? banner.textDown : banner.textUp
        if banner.enabled && !bannerText.isEmpty {
            let escapedText = bannerText.replacingOccurrences(of: "\"", with: "\\\"")
            let escapedTitle = banner.title.replacingOccurrences(of: "\"", with: "\\\"")
            let script = "display notification \"\(escapedText)\" with title \"\(escapedTitle)\""
            spawn(SpawnCall(executable: "/usr/bin/osascript", args: ["-e", script]))
        }
    }

    public static let realSpawn: SpawnFn = { call in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: call.executable)
        p.arguments = call.args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AlerterTests`
Expected: all six tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/NetSentry/Alerter.swift Tests/NetSentryTests/AlerterTests.swift
git commit -m "feat: Alerter with injectable spawn for testability"
```

---

## Task 7: PathMonitor (NWPathMonitor wrapper, no unit tests)

**Files:**
- Create: `Sources/NetSentry/PathMonitor.swift`

PathMonitor is a thin shim around `NWPathMonitor` that translates kernel callbacks into `LinkState` events on a target queue. Not unit-tested because it depends on the kernel; covered by the end-to-end test in Task 11.

- [ ] **Step 1: Implement `PathMonitor.swift`**

`Sources/NetSentry/PathMonitor.swift`:
```swift
import Foundation
import Network

public final class PathMonitor {
    private let monitor = NWPathMonitor()
    private let internalQueue = DispatchQueue(label: "link.smirnov.net-sentry.path-monitor")
    private let targetQueue: DispatchQueue
    private let onState: (LinkState) -> Void

    public init(targetQueue: DispatchQueue, onState: @escaping (LinkState) -> Void) {
        self.targetQueue = targetQueue
        self.onState = onState
    }

    public func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let next: LinkState = (path.status == .satisfied) ? .online : .offline
            self.targetQueue.async {
                self.onState(next)
            }
        }
        monitor.start(queue: internalQueue)
    }

    public func cancel() {
        monitor.cancel()
    }
}
```

- [ ] **Step 2: Verify the library still builds**

Run: `swift build`
Expected: PASS — clean build of the `NetSentry` library + `net-sentry-cli` executable + tests.

- [ ] **Step 3: Run full test suite to confirm nothing regressed**

Run: `swift test`
Expected: all tests from Tasks 2–6 PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/NetSentry/PathMonitor.swift
git commit -m "feat: PathMonitor — NWPathMonitor wrapper"
```

---

## Task 8: Wire the CLI in `main.swift`

**Files:**
- Modify: `Sources/net-sentry-cli/main.swift`

Glue all components together: load config, build the pipeline, run the run loop forever.

- [ ] **Step 1: Replace the placeholder `main.swift`**

`Sources/net-sentry-cli/main.swift`:
```swift
import Foundation
import NetSentry

let stateQueue = DispatchQueue(label: "link.smirnov.net-sentry.state")

let load = ConfigLoader.load(path: ConfigLoader.defaultPath)
switch load.diagnostic {
case .ok:
    FileHandle.standardError.write(Data("net-sentry: loaded config from \(ConfigLoader.defaultPath)\n".utf8))
case .fileMissing:
    FileHandle.standardError.write(Data("net-sentry: no config file at \(ConfigLoader.defaultPath); using defaults\n".utf8))
case .parseError(let msg):
    FileHandle.standardError.write(Data("net-sentry: config parse error: \(msg); using defaults\n".utf8))
}

let config = load.config
let alerter = Alerter(config: config)
let stateMachine = StateMachine { transition in
    alerter.fire(transition)
}

let debounceWindow: DispatchTimeInterval = .milliseconds(Int(config.debounce.seconds * 1000))
let debouncer = Debouncer<LinkState>(window: debounceWindow, queue: stateQueue) { state in
    stateMachine.handle(state)
}

let monitor = PathMonitor(targetQueue: stateQueue) { state in
    debouncer.submit(state)
}
monitor.start()

FileHandle.standardError.write(Data("net-sentry: running; debounce=\(config.debounce.seconds)s\n".utf8))

dispatchMain()   // never returns; serviced by libdispatch + run loop
```

- [ ] **Step 2: Build**

Run: `swift build -c release`
Expected: PASS, produces `.build/release/net-sentry`.

- [ ] **Step 3: Smoke-test in foreground**

Run: `.build/release/net-sentry`
Expected:
- Two stderr lines: `net-sentry: loaded config from ...` (or `no config file ...; using defaults`) and `net-sentry: running; debounce=2.0s`
- Process keeps running, NO alert fires immediately (seed-without-alert behavior)
- Ctrl-C exits cleanly

- [ ] **Step 4: Smoke-test the down → up cycle (manual)**

With the binary still running in foreground:
1. Turn off Wi-Fi from the menu bar.
2. Within ~2–3 seconds, expect:
   - macOS speaks "Internet is down" via the default voice
   - A modal dialog "Internet is down" appears
   - A notification banner appears
3. Turn Wi-Fi back on.
4. Within ~2–3 seconds, expect:
   - A notification banner saying "Internet is back"
   - NO speech, NO modal

If any channel misbehaves, dismiss the modal and Ctrl-C; debug before continuing.

- [ ] **Step 5: Commit**

```bash
git add Sources/net-sentry-cli/main.swift
git commit -m "feat: wire CLI — ConfigLoader → PathMonitor → Debouncer → StateMachine → Alerter"
```

---

## Task 9: LaunchAgent plist + config.example.toml

**Files:**
- Create: `link.smirnov.net-sentry.plist`
- Create: `config.example.toml`

- [ ] **Step 1: Create the plist with `__HOME__` placeholders**

`link.smirnov.net-sentry.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>link.smirnov.net-sentry</string>
    <key>ProgramArguments</key>
    <array>
        <string>__HOME__/.local/bin/net-sentry</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>__HOME__/Library/Logs/net-sentry.out.log</string>
    <key>StandardErrorPath</key>
    <string>__HOME__/Library/Logs/net-sentry.err.log</string>
</dict>
</plist>
```

- [ ] **Step 2: Create `config.example.toml`**

`config.example.toml`:
```toml
# net-sentry configuration
# Lives at: ~/Library/Application Support/net-sentry/config.toml
# Edits require: launchctl kickstart -k gui/$(id -u)/link.smirnov.net-sentry

[debounce]
seconds = 2.0

[notifiers.speech]
enabled = true
voice = "Samantha"            # `say -v ?` for the full list
text_down = "Internet is down"
text_up = ""                  # empty = skip recovery direction

[notifiers.modal]
enabled = true
icon = "stop"                 # stop | caution | note
timeout_seconds = 30          # auto-dismiss; 0 = block forever
text_down = "Internet is down"
text_up = ""

[notifiers.banner]
enabled = true
title = "Net Sentry"
text_down = "Internet is down"
text_up = "Internet is back"
```

- [ ] **Step 3: Commit**

```bash
git add link.smirnov.net-sentry.plist config.example.toml
git commit -m "feat: LaunchAgent plist + example config"
```

---

## Task 10: install.sh

**Files:**
- Create: `install.sh`

- [ ] **Step 1: Create `install.sh`**

`install.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Building (release)..."
swift build -c release

echo "==> Installing binary to ~/.local/bin/..."
install -d "$HOME/.local/bin"
install ".build/release/net-sentry" "$HOME/.local/bin/net-sentry"

echo "==> Seeding config (only if absent)..."
CONFIG_DIR="$HOME/Library/Application Support/net-sentry"
install -d "$CONFIG_DIR"
if [ -f "$CONFIG_DIR/config.toml" ]; then
    echo "    config.toml already exists — preserving your edits"
else
    cp config.example.toml "$CONFIG_DIR/config.toml"
    echo "    copied config.example.toml -> $CONFIG_DIR/config.toml"
fi

echo "==> Installing LaunchAgent..."
install -d "$HOME/Library/Logs"
install -d "$HOME/Library/LaunchAgents"
sed "s|__HOME__|$HOME|g" link.smirnov.net-sentry.plist \
    > "$HOME/Library/LaunchAgents/link.smirnov.net-sentry.plist"

echo "==> Bootstrapping daemon..."
launchctl bootout  "gui/$(id -u)/link.smirnov.net-sentry" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/link.smirnov.net-sentry.plist"

sleep 1
if pgrep -fq "$HOME/.local/bin/net-sentry"; then
    echo "==> ✓ net-sentry is running."
else
    echo "==> ✗ daemon failed to start; check ~/Library/Logs/net-sentry.err.log"
    exit 1
fi
```

- [ ] **Step 2: Make executable**

Run: `chmod +x install.sh`
Expected: no output.

- [ ] **Step 3: Run install**

Run: `./install.sh`
Expected:
- Build succeeds
- Binary copied to `~/.local/bin/net-sentry`
- Config seeded at `~/Library/Application Support/net-sentry/config.toml`
- LaunchAgent loaded and `pgrep` confirms the process is running
- Final line: `==> ✓ net-sentry is running.`

- [ ] **Step 4: Verify the daemon is alive**

Run: `pgrep -af net-sentry`
Expected: one PID line referencing `~/.local/bin/net-sentry`.

Run: `launchctl print "gui/$(id -u)/link.smirnov.net-sentry" | grep state`
Expected: `state = running`.

- [ ] **Step 5: Verify down/up alerts work as installed daemon**

1. Turn Wi-Fi off; within ~2–3 s expect speech + modal + banner.
2. Turn Wi-Fi back on; within ~2–3 s expect banner only.

If any alert misbehaves, check `~/Library/Logs/net-sentry.err.log`.

- [ ] **Step 6: Commit**

```bash
git add install.sh
git commit -m "feat: install script — build, seed config, bootstrap LaunchAgent"
```

---

## Task 11: uninstall.sh

**Files:**
- Create: `uninstall.sh`

- [ ] **Step 1: Create `uninstall.sh`**

`uninstall.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail

echo "==> Bootout LaunchAgent (if loaded)..."
launchctl bootout "gui/$(id -u)/link.smirnov.net-sentry" 2>/dev/null || true

echo "==> Removing LaunchAgent plist..."
rm -f "$HOME/Library/LaunchAgents/link.smirnov.net-sentry.plist"

echo "==> Removing binary..."
rm -f "$HOME/.local/bin/net-sentry"

echo "==> Preserved (NOT removed): $HOME/Library/Application Support/net-sentry/config.toml"
echo "==> Preserved (NOT removed): $HOME/Library/Logs/net-sentry.{out,err}.log"

echo "==> ✓ uninstalled."
```

- [ ] **Step 2: Make executable**

Run: `chmod +x uninstall.sh`

- [ ] **Step 3: Test uninstall + reinstall idempotency**

Run: `./uninstall.sh`
Expected: success, daemon stops; `pgrep -f net-sentry` returns nothing.

Run: `./install.sh`
Expected: clean reinstall; existing config.toml is preserved (script prints "config.toml already exists — preserving your edits").

- [ ] **Step 4: Commit**

```bash
git add uninstall.sh
git commit -m "feat: uninstall script (preserves config and logs)"
```

---

## Task 12: End-to-end manual test from the spec

**No files modified.** This is a verification pass against the spec's testing checklist.

- [ ] **Step 1: Smoke test (seed-without-alert)**

Confirm the daemon was started fresh by `./install.sh`. Watch `~/Library/Logs/net-sentry.err.log`:

Run: `tail -n 20 ~/Library/Logs/net-sentry.err.log`
Expected: lines `net-sentry: loaded config ...` and `net-sentry: running; debounce=2.0s`. NO alerts fired at startup.

- [ ] **Step 2: Down path**

Turn Wi-Fi off via the menu bar.
Within 2–3 seconds, expect simultaneously:
- Spoken voice "Internet is down"
- Modal dialog "Internet is down" with stop icon
- Notification banner "Internet is down" with title "Net Sentry"

- [ ] **Step 3: Recovery path**

Turn Wi-Fi back on.
Within 2–3 seconds, expect:
- Notification banner "Internet is back"
- NO spoken voice, NO modal

- [ ] **Step 4: Debounce — rapid flap should NOT alert**

Toggle Wi-Fi off then back on within ~1 second.
Expect: NO alert at all (debounce window suppresses the transient).

- [ ] **Step 5: Concurrency — modal must not delay speech**

Repeat Step 2 but listen carefully: the spoken voice should begin within ~200 ms of the modal appearing, not after dismissing the modal. (If speech only starts after closing the modal, Process spawning is incorrectly serial — bug.)

- [ ] **Step 6: launchd respawn**

Run: `pkill -f "$HOME/.local/bin/net-sentry"`
Wait 5 seconds.
Run: `pgrep -af net-sentry`
Expected: a new PID — launchd respawned the process.

- [ ] **Step 7: Config tweak**

Edit `~/Library/Application Support/net-sentry/config.toml` and set `[notifiers.modal]` `enabled = false`.

Run: `launchctl kickstart -k "gui/$(id -u)/link.smirnov.net-sentry"`

Repeat Step 2; expect speech + banner, NO modal.

Restore the config (set `enabled = true` again) and `kickstart -k` once more.

- [ ] **Step 8: Tag the verified release**

```bash
git tag -a v0.1.0 -m "net-sentry v0.1.0 — initial verified release"
```

