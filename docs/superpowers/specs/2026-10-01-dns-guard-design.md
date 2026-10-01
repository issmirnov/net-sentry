# net-sentry DNS Guard — Design

**Status:** Approved 2026-10-01
**Last updated:** 2026-10-01
**Extends:** [`2026-04-29-net-sentry-design.md`](2026-04-29-net-sentry-design.md)

## Problem

The author pins the Mac's DNS to a home Pi-hole (`10.3.32.102`) to get network-wide ad-blocking everywhere, including while roaming — the route to that Pi-hole rides a WireGuard tunnel (opnsense road-warrior, `utun` → `10.7.0.0/24`). This works until WireGuard drops: the route to `10.3.32.102` disappears, but the physical internet (Wi-Fi) stays up. macOS keeps sending every DNS query to an unreachable resolver, so **all name resolution fails while the internet is otherwise fine** — "the network is busted."

The existing net-sentry daemon cannot help here: it tracks `NWPath` *satisfiability*, which stays `.satisfied` throughout this failure (the Wi-Fi path is healthy). The tunnel dying is invisible to that signal.

We want net-sentry to additionally watch the reachability of a configured DNS server and, when it becomes unreachable, **clear the DNS override** from the managed network service(s) so macOS falls back to DHCP-provided DNS (working internet). When the server becomes reachable again, **re-pin it** so Pi-hole ad-blocking resumes. Opt-in, config-driven, event-driven, no polling.

## Goals

- Detect loss of reachability to a configured "known DNS" IP within a few seconds, event-driven, no polling.
- On loss: clear that DNS from the managed service(s), restoring working (DHCP) DNS.
- On recovery: re-pin the known DNS on the service(s) it cleared.
- Never clobber a DNS value the user set deliberately to something else.
- Correct after daemon restart/crash and when launched mid-outage — no persistent state file.
- Entirely optional: a new `[dns_guard]` TOML section, disabled by default. Existing installs are byte-for-byte unaffected.
- Stay within the project's constraints: no new runtime dependency, no root, no module restructure, tiny.

## Non-goals

- Active DNS probing (e.g. confirming the Pi-hole *answers* queries). The trigger is route/tunnel reachability, matching the "WireGuard is down" failure. A Pi-hole process that dies while the tunnel stays up is out of scope (documented limitation).
- Managing multiple distinct known-DNS watches in v1. The config is shaped to grow into that (see Extensibility) but ships single-watch.
- Auto-detecting which services to manage. v1 uses an explicit `services` list (see Reconciliation rationale).
- Hot-reload of config (inherited v0.2 item from the base project).

## Architecture

A **second, independent pipeline** added alongside the existing alert pipeline. It reuses the generic `Debouncer<Value>`; it does **not** use `StateMachine` (see "Why no StateMachine").

```
EXISTING (unchanged):
  NWPathMonitor ─► PathMonitor ─► Debouncer<LinkState> ─► StateMachine ─► Alerter

NEW (only when [dns_guard].enabled):
  SCNetworkReachability(known_dns) ─► ReachabilityMonitor ─► Debouncer<Reachability> ─► DNSGuard.reconcile
        (route to 10.3.32.102                (emits .reachable/        (rides out WG           (idempotent:
         appears / disappears,                .unreachable on          reconnect flaps)         .unreachable ⇒ clear
         kernel event, no poll)               the dns queue)                                    .reachable  ⇒ restore)
                                                                                                      │
                                                                                                      ▼
                                                                                      /usr/sbin/networksetup -setdnsservers
                                                                                      (+ optional banner via /usr/bin/osascript)
```

**ReachabilityMonitor.** Owns an `SCNetworkReachability` reference created for the `known_dns` IP (`SCNetworkReachabilityCreateWithName`/`...WithAddress`). Registers a callback on a dedicated serial queue via `SCNetworkReachabilitySetDispatchQueue`. Maps the reachability flags to `.reachable` when flags contain `.reachable` and not `.connectionRequired`, else `.unreachable`, and forwards that onto the target queue. Emits an **initial** state at start (SystemConfiguration delivers an initial callback on queue registration; if absent, a one-shot `SCNetworkReachabilityGetFlags` seeds it) so startup state is always reconciled. Thin wrapper, no unit test — pure kernel side-effect, exactly like `PathMonitor`.

**Debouncer<Reachability>.** The existing generic `Debouncer`, reused. Each reachability change cancels the pending work item and reschedules `dns_guard.debounce_seconds` out. Only a state that persists the full window reaches `DNSGuard`. This rides out the brief flaps a WireGuard reconnect produces.

**DNSGuard.** The reconciler + action. Mirrors `Alerter`: holds its config slice and **injected side-effects** so tests record calls instead of touching the real network. `reconcile(_:)` is **idempotent** — it reads the current DNS of each managed service and writes only when a change is required.

## Why no StateMachine (idempotent reconcile instead)

`StateMachine` suppresses the first event (silent seed) and fires only on transitions. That is correct for *alerts* (don't scream on launch) but wrong for a DNS reconciler: a daemon **launched mid-outage** (booted while away, WireGuard not yet up, Wi-Fi still carrying a stale Pi-hole pin) would leave DNS broken until reachability *changed*.

Because `reconcile` is idempotent (reads live DNS, writes only on need), running it on **every** debounced reachability sample — seed and steady-state included — is both simpler (one fewer component in this pipeline) and strictly more robust: it always converges the managed services to the desired state. Steady-state samples cost one cheap `-getdnsservers` read and no write.

## Reconciliation model (stateless, observed-value)

For each service named in `dns_guard.services`, on each debounced reachability sample:

- **`.unreachable`** → if the service's current DNS is **exactly `[known_dns]`**, clear it (`networksetup -setdnsservers <svc> empty`).
- **`.reachable`** → if the service's current DNS is **empty**, set it to `known_dns` (`networksetup -setdnsservers <svc> <known_dns>`).

Decisions are made from **currently observed** DNS values, never remembered history. Consequences:

- **No state file.** Correct across daemon restart, crash, and mid-outage launch for free — the next sample re-derives the right action from live state. (Honors the base project's "no persistent state" stance.)
- **Won't clobber a deliberate override.** If the user sets a managed service to `1.1.1.1`, it is neither `[known_dns]` (so never cleared) nor empty (so never overwritten) — DNS Guard leaves it alone in both directions.
- **Conservative match.** A service whose DNS is `[10.3.32.102, 1.1.1.1]` is not exactly `[known_dns]`, so it is not managed. DNS Guard only touches a service whose override is *exactly and only* the known DNS, or empty.
- **"Owned service" edge:** on a managed service, a manual *empty* value while reachable will be re-pinned to `known_dns` (empty is the restore trigger). Listing a service in `services` means "I want `known_dns` here whenever it is reachable." Documented in README.

**Notification.** When `notify = true`, a banner fires via `osascript` **only if at least one service was actually mutated** in that reconcile pass — so steady-state and no-op passes are silent. Down banner e.g. `"Pi-hole unreachable — DNS cleared"`, up banner `"Pi-hole reachable — DNS restored"`. Text is derived, not configurable in v1 (YAGNI; the alert pipeline already owns rich notifier config).

## Component contracts

```swift
// New, in Sources/NetSentry/

public enum Reachability: Equatable { case reachable, unreachable }

public final class ReachabilityMonitor {
    public init(host: String, targetQueue: DispatchQueue, onState: @escaping (Reachability) -> Void)
    public func start()   // registers SCNetworkReachability callback + emits initial state
    public func cancel()
}

// Injected side-effects → tests record, production hits networksetup.
public struct DNSBackend {
    public var currentDNS: (_ service: String) -> [String]          // [] when none set
    public var setDNS:     (_ service: String, _ servers: [String]) -> Void   // [] clears ("empty")
    public static let real: DNSBackend                               // shells out to /usr/sbin/networksetup
}

public final class DNSGuard {
    public init(config: Config.DNSGuard,
                backend: DNSBackend = .real,
                notify: @escaping SpawnFn = Alerter.realSpawn)
    public func reconcile(_ r: Reachability)   // idempotent
}
```

`DNSBackend.real.currentDNS` runs `/usr/sbin/networksetup -getdnsservers <svc>` and parses: a line equal to `There aren't any DNS Servers set on <svc>.` → `[]`; otherwise the IP lines. `setDNS` runs `-setdnsservers <svc> empty` for `[]`, else `-setdnsservers <svc> <servers...>`. Absolute path (launchd does not inherit PATH — same convention as `/usr/bin/say`). Writes are fire-and-forget via the same `SpawnFn`/`realSpawn` pattern; the read captures stdout (a small addition over `Alerter`'s write-only spawn).

## Config schema (TOML)

New optional section. Merged per-key over `Config.defaults`, so absent = default (honors invariant #4).

```toml
[dns_guard]
enabled = false            # opt-in; off by default
known_dns = "10.3.32.102"  # DNS server IP to watch (reachability) and manage
services = ["Wi-Fi"]       # network service(s) whose DNS override DNS Guard owns
debounce_seconds = 3.0     # how long known_dns must stay unreachable before clearing (rides out WG reconnect flaps)
notify = true              # banner when it clears / restores
```

Repo-shipped defaults stay generic so the public repo carries no personal data:

```swift
public struct DNSGuard: Equatable {
    public var enabled: Bool          // false
    public var knownDNS: String       // ""   → if enabled with empty knownDNS, log a warning and run as no-op
    public var services: [String]     // ["Wi-Fi"]
    public var debounceSeconds: Double // 3.0
    public var notify: Bool           // true
}
```

The author's real values live only in `~/Library/Application Support/net-sentry/config.toml`. `config.example.toml` shows the section with a commented, illustrative `known_dns`.

## Privilege model

Verified empirically on the target machine: `/usr/sbin/networksetup -setdnsservers Wi-Fi 10.3.32.102` returns exit 0 with **no sudo and no prompt** when run by the (admin-group) user in the `gui/$(id -u)` LaunchAgent domain. So the DNS mutation runs in the **same user LaunchAgent** as the alerter — no root, no LaunchDaemon split, no sudoers entry. This upholds `CLAUDE.md`'s "Don't elevate to root" invariant (which exists so `say`/`osascript` keep their GUI session).

**Documented requirement:** this relies on the running user being an admin. A standard-user install would need elevation and is out of scope.

## Concurrency

The new pipeline runs on its own serial queue `link.smirnov.net-sentry.dns`. The two pipelines share **no mutable state** — separate monitors, separate debouncer instances, and `DNSGuard` keeps no state (it reads live DNS each pass). So:

- No locking across pipelines.
- A `networksetup` read/write (tens of ms, blocking) runs on the dns queue and never delays the alert pipeline's speech/modal/banner.

## Wiring (main.swift)

After the existing pipeline, only when `config.dnsGuard.enabled` and `known_dns` is non-empty.

**Lifetime:** `main.swift` is top-level script code, so the pipeline refs must be bound at top-level scope — bindings inside an `if { … }` block are deallocated at the block's close, tearing down `SCNetworkReachability` before `dispatchMain()`. The base daemon relies on `let monitor = …` being top-level for exactly this reason. Hold the new chain in a top-level `var`:

```swift
var dnsPipeline: [AnyObject] = []            // top-level: retains the chain for the process lifetime
if config.dnsGuard.enabled, !config.dnsGuard.knownDNS.isEmpty {
    let dnsQueue = DispatchQueue(label: "link.smirnov.net-sentry.dns")
    let dnsGuard = DNSGuard(config: config.dnsGuard)          // reads config.notify internally
    let dnsDebouncer = Debouncer<Reachability>(
        window: .milliseconds(Int(config.dnsGuard.debounceSeconds * 1000)),
        queue: dnsQueue) { [dnsGuard] r in dnsGuard.reconcile(r) }
    let reach = ReachabilityMonitor(host: config.dnsGuard.knownDNS, targetQueue: dnsQueue) {
        [dnsDebouncer] r in dnsDebouncer.submit(r)
    }
    reach.start()
    dnsPipeline = [dnsGuard, dnsDebouncer, reach]            // keep-alive
} else if config.dnsGuard.enabled {
    FileHandle.standardError.write(Data("net-sentry: dns_guard enabled but known_dns is empty; skipping\n".utf8))
}
```

## File layout delta

```
Sources/NetSentry/ReachabilityMonitor.swift   # new — SCNetworkReachability wrapper
Sources/NetSentry/DNSGuard.swift              # new — reconciler + DNSBackend
Sources/NetSentry/Config.swift                # +DNSGuard struct, +default
Sources/NetSentry/ConfigLoader.swift          # +[dns_guard] merge
Sources/net-sentry-cli/main.swift             # +second pipeline (guarded by enabled)
Tests/NetSentryTests/DNSGuardTests.swift      # new
Tests/NetSentryTests/ConfigLoaderTests.swift  # +[dns_guard] parse cases
Tests/NetSentryTests/ConfigDefaultsTests.swift# +dns_guard defaults assertion
config.example.toml                           # +[dns_guard] section (commented example IP)
README.md, CLAUDE.md                          # +feature docs, +new invariant
```

No change to `Package.swift` — `SystemConfiguration` is a system framework, imported directly (`import SystemConfiguration`), no SwiftPM dependency.

## New invariant (add to CLAUDE.md)

> **DNS Guard reconciles on every debounced sample, including the seed.** Unlike the alert `StateMachine` (silent first-event seed), `DNSGuard.reconcile` must run on the first reachability sample so a daemon launched mid-outage clears a stale pin immediately. This is safe because `reconcile` is idempotent (reads live DNS, writes only on need). Do not "optimize" it into transition-only firing.

## Error handling

| Failure mode | Behavior |
|---|---|
| `networksetup` read returns unexpected text | Treat as "not exactly `[known_dns]` and not empty" → service is left untouched (safe default); logged to stderr |
| `networksetup` set returns non-zero | Logged to stderr; daemon continues (next reconcile retries from live state) |
| `[dns_guard].enabled = true` but `known_dns = ""` | Warning to stderr; pipeline not started (no-op) |
| `SCNetworkReachability` create fails for `known_dns` | Warning to stderr; pipeline not started; alert pipeline unaffected |
| Config missing/malformed `[dns_guard]` | Per-key merge over defaults → section absent means `enabled=false` → feature off |
| Daemon crash mid-outage | launchd `KeepAlive` respawns; seed reconcile re-derives correct action from live DNS |

## Testing (strict TDD)

`DNSGuard` is unit-tested through an injected `DNSBackend` recorder + `SpawnFn` recorder:

1. `.unreachable` + service DNS `== [known_dns]` → one `setDNS(svc, [])`; notify banner recorded.
2. `.unreachable` + service DNS `== [1.1.1.1]` → no `setDNS`; no banner.
3. `.reachable` + service DNS empty → one `setDNS(svc, [known_dns])`; banner.
4. `.reachable` + service DNS `== [1.1.1.1]` → no write; no banner.
5. `.reachable` + service already `== [known_dns]` → no write; no banner (idempotent steady state).
6. Multiple `services` → each evaluated independently.
7. `notify = false` → never spawns a banner even when mutating.
8. Idempotence: two identical reconciles → writes only on the first.

`ReachabilityMonitor` has no unit test (kernel callback, same rationale as `PathMonitor`). `ConfigLoaderTests` gains `[dns_guard]` parse + partial-section + absent-section cases; `ConfigDefaultsTests` asserts the new defaults.

**Manual E2E** (during install verification):

1. Smoke: `enabled=false` default build behaves exactly as before (no second pipeline).
2. Enable with `known_dns=10.3.32.102`, `services=["Wi-Fi"]`; confirm Wi-Fi currently `== 10.3.32.102`.
3. Bring WireGuard down (`wg-quick down <tunnel>` / toggle). Within ~`debounce+1`s: Wi-Fi DNS cleared (`networksetup -getdnsservers Wi-Fi` → "There aren't any…"), DNS resolves again, banner shown.
4. Bring WireGuard back up. Within ~`debounce+1`s: Wi-Fi DNS re-pinned to `10.3.32.102`, banner shown.
5. Flap test: toggle WireGuard off/on within the debounce window → no DNS change.
6. Override test: set Wi-Fi to `1.1.1.1`, drop WireGuard → unchanged (not managed).
7. Mid-outage launch: with WireGuard down and Wi-Fi pinned, `launchctl kickstart -k` the daemon → Wi-Fi cleared on seed.

## Extensibility (future, not v1)

The single `[dns_guard]` section promotes to an array of watches without breaking existing configs:

```toml
[[dns_guard.watch]]
known_dns = "10.3.32.102"
services  = ["Wi-Fi"]

[[dns_guard.watch]]
known_dns = "10.3.32.103"
services  = ["Thunderbolt Ethernet Slot 0"]
```

`Config.DNSGuard` becomes `{ enabled, debounce_seconds, notify, watches: [Watch] }`; the loader reads the table-array; `main` spins one `ReachabilityMonitor`+`Debouncer`+`DNSGuard` per watch on the shared dns queue. Auto-detect of services (drop the explicit list) is the other extension; it requires remembering the managed set, so it is deferred with that cost noted. Both are documented in `CLAUDE.md` "Common tasks".

## Limitations (v1)

- **Route reachability, not active probe.** WireGuard up but Pi-hole process down → route exists → no trigger.
- **Admin user required** for the password-free `networksetup` write.
- **Exact-match management only** — a service mixing `known_dns` with other resolvers is left untouched by design.
