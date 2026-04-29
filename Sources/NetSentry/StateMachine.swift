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
