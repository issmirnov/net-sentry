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
}
