import Foundation
import TOMLKit

public enum ConfigDiagnostic: Equatable {
    case ok
    case fileMissing
    case parseError(String)
}

public struct ConfigLoadResult: Equatable {
    public let config: Config
    public let diagnostic: ConfigDiagnostic
}

public enum ConfigLoader {
    public static let defaultPath: String = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("net-sentry/config.toml").path
    }()

    public static func load(path: String) -> ConfigLoadResult {
        guard FileManager.default.fileExists(atPath: path) else {
            return ConfigLoadResult(config: .defaults, diagnostic: .fileMissing)
        }
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            return ConfigLoadResult(config: .defaults, diagnostic: .parseError("could not read file"))
        }
        do {
            let table = try TOMLTable(string: raw)
            let merged = merge(defaults: .defaults, with: table)
            return ConfigLoadResult(config: merged, diagnostic: .ok)
        } catch {
            return ConfigLoadResult(config: .defaults, diagnostic: .parseError(String(describing: error)))
        }
    }

    private static func merge(defaults: Config, with t: TOMLTable) -> Config {
        var c = defaults

        if let d = t["debounce"]?.table {
            if let v = d["seconds"]?.double { c.debounce.seconds = v }
            else if let v = d["seconds"]?.int { c.debounce.seconds = Double(v) }
        }

        if let n = t["notifiers"]?.table {
            if let s = n["speech"]?.table {
                if let v = s["enabled"]?.bool      { c.notifiers.speech.enabled  = v }
                if let v = s["voice"]?.string      { c.notifiers.speech.voice    = v }
                if let v = s["text_down"]?.string  { c.notifiers.speech.textDown = v }
                if let v = s["text_up"]?.string    { c.notifiers.speech.textUp   = v }
            }
            if let m = n["modal"]?.table {
                if let v = m["enabled"]?.bool             { c.notifiers.modal.enabled        = v }
                if let v = m["icon"]?.string              { c.notifiers.modal.icon           = v }
                if let v = m["timeout_seconds"]?.int      { c.notifiers.modal.timeoutSeconds = v }
                if let v = m["text_down"]?.string         { c.notifiers.modal.textDown       = v }
                if let v = m["text_up"]?.string           { c.notifiers.modal.textUp         = v }
            }
            if let b = n["banner"]?.table {
                if let v = b["enabled"]?.bool      { c.notifiers.banner.enabled  = v }
                if let v = b["title"]?.string      { c.notifiers.banner.title    = v }
                if let v = b["text_down"]?.string  { c.notifiers.banner.textDown = v }
                if let v = b["text_up"]?.string    { c.notifiers.banner.textUp   = v }
            }
        }
        return c
    }
}
