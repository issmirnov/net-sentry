import Foundation

public struct SpawnCall: Equatable {
    public let executable: String
    public let args: [String]
}

public typealias SpawnFn = (SpawnCall) -> Void

public final class Alerter {
    private let config: Config
    private let spawn: SpawnFn

    public init(config: Config, spawn: @escaping SpawnFn = Alerter.realSpawn) {
        self.config = config
        self.spawn = spawn
    }

    public func fire(_ direction: Transition) {
        let isDown = (direction == .down)

        let speech = config.notifiers.speech
        let speechText = isDown ? speech.textDown : speech.textUp
        if speech.enabled && !speechText.isEmpty {
            spawn(SpawnCall(executable: "/usr/bin/say", args: ["-v", speech.voice, speechText]))
        }

        let modal = config.notifiers.modal
        let modalText = isDown ? modal.textDown : modal.textUp
        if modal.enabled && !modalText.isEmpty {
            let escaped = Alerter.escapeForAppleScript(modalText)
            let timeoutClause = modal.timeoutSeconds > 0 ? " giving up after \(modal.timeoutSeconds)" : ""
            let script = "display dialog \"\(escaped)\" with icon \(modal.icon) buttons {\"OK\"} default button \"OK\"\(timeoutClause)"
            spawn(SpawnCall(executable: "/usr/bin/osascript", args: ["-e", script]))
        }

        let banner = config.notifiers.banner
        let bannerText = isDown ? banner.textDown : banner.textUp
        if banner.enabled && !bannerText.isEmpty {
            let escapedText = Alerter.escapeForAppleScript(bannerText)
            let escapedTitle = Alerter.escapeForAppleScript(banner.title)
            let script = "display notification \"\(escapedText)\" with title \"\(escapedTitle)\""
            spawn(SpawnCall(executable: "/usr/bin/osascript", args: ["-e", script]))
        }
    }

    static func escapeForAppleScript(_ s: String) -> String {
        // Backslash MUST come first so we don't double-escape the backslashes
        // we introduce when escaping quotes.
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    public static let realSpawn: SpawnFn = { call in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: call.executable)
        p.arguments = call.args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        // Fire-and-forget: child is reparented to launchd on `p` dealloc,
        // which reaps the zombie. Safe for short-lived processes only.
        try? p.run()
    }
}
