import Foundation
import Network

/// Wakes on NWPathMonitor interface changes (WireGuard's utun appearing or
/// disappearing is such a change) and, on each change plus once at startup,
/// runs a single short-timeout TCP probe to known_dns:53. `.ready` → reachable;
/// failure or timeout → unreachable. The host must be an IP literal (resolving
/// a name would need the very DNS that may be broken).
public final class ResolverProbe {
    private let host: String
    private let port: UInt16
    private let timeout: TimeInterval
    private let targetQueue: DispatchQueue
    private let onResult: (Reachability) -> Void

    private let monitor = NWPathMonitor()
    private let internalQueue = DispatchQueue(label: "link.smirnov.net-sentry.resolver-probe")

    public init(
        host: String, port: UInt16 = 53, timeout: TimeInterval,
        targetQueue: DispatchQueue, onResult: @escaping (Reachability) -> Void
    ) {
        self.host = host
        self.port = port
        self.timeout = timeout
        self.targetQueue = targetQueue
        self.onResult = onResult
    }

    public func start() {
        monitor.pathUpdateHandler = { [weak self] _ in self?.probe() }
        monitor.start(queue: internalQueue)
        probe()  // explicit seed; pathUpdateHandler also fires once, but don't depend on that
    }

    public func cancel() {
        monitor.cancel()
    }

    private func probe() {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            FileHandle.standardError.write(Data("net-sentry: dns_guard invalid port \(port)\n".utf8))
            return
        }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)

        // State callbacks and the timeout both run on internalQueue (serial),
        // so `finished` needs no lock.
        var finished = false
        func finish(_ result: Reachability) {
            if finished { return }
            finished = true
            conn.cancel()
            let cb = onResult
            targetQueue.async { cb(result) }
        }

        conn.stateUpdateHandler = { state in
            switch state {
            case .ready: finish(.reachable)
            case .failed, .cancelled: finish(.unreachable)
            default: break  // .waiting (no route) rides the timeout
            }
        }
        conn.start(queue: internalQueue)
        internalQueue.asyncAfter(deadline: .now() + timeout) { finish(.unreachable) }
    }
}
