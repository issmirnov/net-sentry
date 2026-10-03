import Foundation

public enum Reachability: Equatable {
    case reachable
    case unreachable
}

/// Reads and writes a network service's DNS override. Injected so tests record
/// calls; production (`.real`) shells out to `/usr/sbin/networksetup`.
public struct DNSBackend {
    public var currentDNS: (_ service: String) -> [String]
    public var setDNS: (_ service: String, _ servers: [String]) -> Void

    public init(
        currentDNS: @escaping (_ service: String) -> [String],
        setDNS: @escaping (_ service: String, _ servers: [String]) -> Void
    ) {
        self.currentDNS = currentDNS
        self.setDNS = setDNS
    }

    /// Parse `networksetup -getdnsservers <svc>` output into resolver IPs.
    /// The empty state prints a localizable sentence; keying on IP *shape*
    /// (not that string) means locale/version drift can't make an empty
    /// service read as configured.
    public static func parseDNSServers(_ output: String) -> [String] {
        output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { isIPAddress($0) }
    }

    static func isIPAddress(_ s: String) -> Bool {
        var v4 = in_addr()
        if s.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 { return true }
        var v6 = in6_addr()
        if s.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 { return true }
        return false
    }

    public static let real = DNSBackend(
        currentDNS: { service in
            parseDNSServers(runCapturing("/usr/sbin/networksetup", ["-getdnsservers", service]))
        },
        setDNS: { service, servers in
            let tail = servers.isEmpty ? ["empty"] : servers
            Alerter.realSpawn(
                SpawnCall(
                    executable: "/usr/sbin/networksetup",
                    args: ["-setdnsservers", service] + tail))
        }
    )

    /// Blocking subprocess run that captures stdout. Unlike `Alerter.realSpawn`
    /// (fire-and-forget, stdout discarded), reading DNS state needs the output,
    /// so this waits. Safe only because DNS Guard runs it on its own dns queue,
    /// never the alert queue. Read-to-EOF before `waitUntilExit` avoids a
    /// pipe-buffer deadlock.
    static func runCapturing(_ executable: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Stateless, observed-value reconciler. On each (debounced) reachability
/// verdict it reads the live DNS of each managed service and writes only when
/// a change is needed — so it is idempotent, needs no persistent state, and
/// never clobbers a value the user set to something other than known_dns.
public final class DNSGuard {
    private let config: Config.DNSGuard
    private let backend: DNSBackend
    private let notify: SpawnFn

    public init(
        config: Config.DNSGuard,
        backend: DNSBackend = .real,
        notify: @escaping SpawnFn = Alerter.realSpawn
    ) {
        self.config = config
        self.backend = backend
        self.notify = notify
    }

    public func reconcile(_ r: Reachability) {
        var mutated = false
        for service in config.services {
            let current = backend.currentDNS(service)
            switch r {
            case .unreachable:
                if current == [config.knownDNS] {
                    backend.setDNS(service, [])
                    mutated = true
                }
            case .reachable:
                if current.isEmpty {
                    backend.setDNS(service, [config.knownDNS])
                    mutated = true
                }
            }
        }
        if mutated && config.notify { fireBanner(r) }
    }

    private func fireBanner(_ r: Reachability) {
        let text =
            (r == .unreachable)
            ? "Pi-hole unreachable — DNS cleared"
            : "Pi-hole reachable — DNS restored"
        let script = "display notification \"\(Alerter.escapeForAppleScript(text))\" with title \"Net Sentry\""
        notify(SpawnCall(executable: "/usr/bin/osascript", args: ["-e", script]))
    }
}
