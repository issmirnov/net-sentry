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
