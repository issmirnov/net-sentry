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

// DNS Guard — second, independent pipeline (opt-in). Top-level `var` so the
// chain survives for the process lifetime; refs inside an if-block would be
// deallocated at its close, tearing down the monitor before dispatchMain().
var dnsPipeline: [AnyObject] = []
if config.dnsGuard.enabled, !config.dnsGuard.knownDNS.isEmpty {
    let dnsQueue = DispatchQueue(label: "link.smirnov.net-sentry.dns")
    let dnsGuard = DNSGuard(config: config.dnsGuard)
    let dnsDebouncer = Debouncer<Reachability>(
        window: .milliseconds(Int(config.dnsGuard.debounceSeconds * 1000)),
        queue: dnsQueue
    ) { [dnsGuard] r in dnsGuard.reconcile(r) }
    let probe = ResolverProbe(
        host: config.dnsGuard.knownDNS,
        port: 53,
        timeout: config.dnsGuard.probeTimeoutSeconds,
        targetQueue: dnsQueue
    ) { [dnsDebouncer] r in dnsDebouncer.submit(r) }
    probe.start()
    dnsPipeline = [dnsGuard, dnsDebouncer, probe]
    FileHandle.standardError.write(Data("net-sentry: dns_guard watching \(config.dnsGuard.knownDNS) on \(config.dnsGuard.services)\n".utf8))
} else if config.dnsGuard.enabled {
    FileHandle.standardError.write(Data("net-sentry: dns_guard enabled but known_dns is empty; skipping\n".utf8))
}
_ = dnsPipeline  // silence "never read" — it exists to retain the chain

FileHandle.standardError.write(Data("net-sentry: running; debounce=\(config.debounce.seconds)s\n".utf8))

dispatchMain()  // never returns; serviced by libdispatch + run loop
