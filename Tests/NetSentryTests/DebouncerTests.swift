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
