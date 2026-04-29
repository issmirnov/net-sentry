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
