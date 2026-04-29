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
