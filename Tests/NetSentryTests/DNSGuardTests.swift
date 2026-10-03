import XCTest
@testable import NetSentry

final class DNSGuardTests: XCTestCase {
    // MARK: parseDNSServers

    func testParseReturnsIPv4Lines() {
        XCTAssertEqual(DNSBackend.parseDNSServers("10.3.32.102\n"), ["10.3.32.102"])
        XCTAssertEqual(DNSBackend.parseDNSServers("1.1.1.1\n8.8.8.8\n"), ["1.1.1.1", "8.8.8.8"])
    }

    func testParseReturnsIPv6Line() {
        XCTAssertEqual(DNSBackend.parseDNSServers("2606:4700:4700::1111\n"), ["2606:4700:4700::1111"])
    }

    func testParseEmptyEnglishSentinelReturnsEmpty() {
        XCTAssertEqual(DNSBackend.parseDNSServers("There aren't any DNS Servers set on Wi-Fi."), [])
    }

    func testParseLocalizedSentinelReturnsEmpty() {
        // No IP lines → empty, regardless of the (localizable) sentence.
        XCTAssertEqual(DNSBackend.parseDNSServers("Es sind keine DNS-Server für Wi-Fi festgelegt."), [])
    }

    func testParseIgnoresSurroundingWhitespace() {
        XCTAssertEqual(DNSBackend.parseDNSServers("  10.3.32.102  \n\n"), ["10.3.32.102"])
    }

    // MARK: reconcile

    private func cfg(services: [String] = ["Wi-Fi"], notify: Bool = true) -> Config.DNSGuard {
        Config.DNSGuard(
            enabled: true, knownDNS: "10.3.32.102", services: services,
            debounceSeconds: 3.0, probeTimeoutSeconds: 2.0, notify: notify)
    }

    private func makeGuard(
        current: @escaping (String) -> [String],
        notify: Bool = true,
        services: [String] = ["Wi-Fi"],
        sets: @escaping (String, [String]) -> Void,
        banners: @escaping (SpawnCall) -> Void
    ) -> DNSGuard {
        DNSGuard(
            config: cfg(services: services, notify: notify),
            backend: DNSBackend(currentDNS: current, setDNS: sets),
            notify: banners)
    }

    func testUnreachableClearsWhenExactlyPinned() {
        var sets: [(String, [String])] = []; var banners: [SpawnCall] = []
        let g = makeGuard(
            current: { _ in ["10.3.32.102"] },
            sets: { sets.append(($0, $1)) }, banners: { banners.append($0) })
        g.reconcile(.unreachable)
        XCTAssertEqual(sets.count, 1)
        XCTAssertEqual(sets.first?.0, "Wi-Fi")
        XCTAssertEqual(sets.first?.1, [])
        XCTAssertEqual(banners.count, 1)
    }

    func testUnreachableLeavesManualOverride() {
        var sets: [(String, [String])] = []; var banners: [SpawnCall] = []
        let g = makeGuard(
            current: { _ in ["1.1.1.1"] },
            sets: { sets.append(($0, $1)) }, banners: { banners.append($0) })
        g.reconcile(.unreachable)
        XCTAssertTrue(sets.isEmpty)
        XCTAssertTrue(banners.isEmpty)
    }

    func testUnreachableNoopWhenAlreadyEmpty() {
        var sets: [(String, [String])] = []; var banners: [SpawnCall] = []
        let g = makeGuard(
            current: { _ in [] },
            sets: { sets.append(($0, $1)) }, banners: { banners.append($0) })
        g.reconcile(.unreachable)
        XCTAssertTrue(sets.isEmpty)
        XCTAssertTrue(banners.isEmpty)
    }

    func testReachableRestoresWhenEmpty() {
        var sets: [(String, [String])] = []; var banners: [SpawnCall] = []
        let g = makeGuard(
            current: { _ in [] },
            sets: { sets.append(($0, $1)) }, banners: { banners.append($0) })
        g.reconcile(.reachable)
        XCTAssertEqual(sets.count, 1)
        XCTAssertEqual(sets.first?.0, "Wi-Fi")
        XCTAssertEqual(sets.first?.1, ["10.3.32.102"])
        XCTAssertEqual(banners.count, 1)
    }

    func testReachableLeavesManualOverride() {
        var sets: [(String, [String])] = []; var banners: [SpawnCall] = []
        let g = makeGuard(
            current: { _ in ["1.1.1.1"] },
            sets: { sets.append(($0, $1)) }, banners: { banners.append($0) })
        g.reconcile(.reachable)
        XCTAssertTrue(sets.isEmpty)
        XCTAssertTrue(banners.isEmpty)
    }

    func testReachableNoopWhenAlreadyPinned() {
        var sets: [(String, [String])] = []; var banners: [SpawnCall] = []
        let g = makeGuard(
            current: { _ in ["10.3.32.102"] },
            sets: { sets.append(($0, $1)) }, banners: { banners.append($0) })
        g.reconcile(.reachable)
        XCTAssertTrue(sets.isEmpty)
        XCTAssertTrue(banners.isEmpty)
    }

    func testMultipleServicesEvaluatedIndependently() {
        var sets: [(String, [String])] = []; var banners: [SpawnCall] = []
        let g = makeGuard(
            current: { svc in svc == "Wi-Fi" ? ["10.3.32.102"] : ["1.1.1.1"] },
            services: ["Wi-Fi", "Ethernet"],
            sets: { sets.append(($0, $1)) }, banners: { banners.append($0) })
        g.reconcile(.unreachable)
        XCTAssertEqual(sets.count, 1)
        XCTAssertEqual(sets.first?.0, "Wi-Fi")
        XCTAssertEqual(banners.count, 1, "one pass that mutated ≥1 service → one banner")
    }

    func testNotifyFalseSuppressesBanner() {
        var sets: [(String, [String])] = []; var banners: [SpawnCall] = []
        let g = makeGuard(
            current: { _ in ["10.3.32.102"] }, notify: false,
            sets: { sets.append(($0, $1)) }, banners: { banners.append($0) })
        g.reconcile(.unreachable)
        XCTAssertEqual(sets.count, 1, "still mutates")
        XCTAssertTrue(banners.isEmpty, "but no banner when notify=false")
    }

    func testBannerIsAnOsascriptNotification() {
        var banners: [SpawnCall] = []
        let g = makeGuard(
            current: { _ in ["10.3.32.102"] },
            sets: { _, _ in }, banners: { banners.append($0) })
        g.reconcile(.unreachable)
        XCTAssertEqual(banners.first?.executable, "/usr/bin/osascript")
        XCTAssertTrue(banners.first?.args.last?.contains("display notification") ?? false)
    }
}
