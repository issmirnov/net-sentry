# net-sentry DNS Guard — Design

**Status:** Approved 2026-10-01 (revised post-review)
**Last updated:** 2026-10-01
**Extends:** [`2026-04-29-net-sentry-design.md`](2026-04-29-net-sentry-design.md)

## Revision history

- **v1 (2026-10-01):** detection via `SCNetworkReachability` on the known-DNS IP.
- **v2 (2026-10-01, post-review):** **detection pivoted** to an `NWPathMonitor`-triggered one-shot active probe. An independent review proved v1's trigger cannot fire in the target scenario: when WireGuard drops, the route to `10.3.32.102` falls through to the Wi-Fi default route, so a route still exists and `SCNetworkReachability` (which reports route existence, not host reachability) keeps saying "reachable." Verified on the target machine — `route get 10.200.200.200` (a stand-in for the un-tunneled Pi-hole) resolves to `destination: default / interface: en0`. The downstream reconciler, config, concurrency, and lifetime design are unchanged from v1.

## Problem

The author pins the Mac's DNS to a home Pi-hole (`10.3.32.102`) for network-wide ad-blocking everywhere, including while roaming — the route to that Pi-hole rides a WireGuard tunnel (opnsense road-warrior, `utun` → `10.7.0.0/24`; the home LAN `10.3/16` is routed over it). This works until WireGuard drops: the specific `10.3/16` route is withdrawn and `10.3.32.102` falls through to the Wi-Fi default route, but the physical internet stays up. macOS keeps sending every DNS query to a resolver it can no longer actually reach, so **all name resolution fails while the internet is otherwise fine** — "the network is busted."

The existing net-sentry daemon cannot help: it tracks `NWPath` *satisfiability*, which stays `.satisfied` throughout (the Wi-Fi path is healthy). The tunnel dying is invisible to that signal.

We want net-sentry to additionally watch whether a configured DNS server actually answers, and when it stops, **clear the DNS override** from the managed network service(s) so macOS falls back to DHCP-provided DNS (working internet). When it answers again, **re-pin it** so Pi-hole ad-blocking resumes. Opt-in, config-driven, event-driven.

## Goals

- Detect that the configured "known DNS" has become unreachable within a few seconds of a WireGuard/route change — driven by OS network-change events, not periodic polling.
- On loss: clear that DNS from the managed service(s), restoring working (DHCP) DNS.
- On recovery: re-pin the known DNS on the service(s) it cleared.
- Never clobber a DNS value the user set deliberately to something else.
- Correct after daemon restart/crash and when launched mid-outage — no persistent state file.
- Entirely optional: a new `[dns_guard]` TOML section, disabled by default. Existing installs are byte-for-byte unaffected.
- Stay within the project's constraints: no new runtime dependency, no root, no module restructure, tiny.

## Non-goals

- **Periodic polling.** The health probe is **one-shot**, fired only on `NWPathMonitor` change events plus one at startup. This is the same shape the base spec already sanctions for its planned captive-portal probe — not a poll loop.
- Managing multiple distinct known-DNS watches in v1. Config is shaped to grow into that (see Extensibility) but ships single-watch.
- Auto-detecting which services to manage. v1 uses an explicit `services` list (see Reconciliation rationale).
- Forcing a resolver-cache flush. `killall -HUP mDNSResponder` needs root, which the project forbids; see "Recovery semantics."
- Hot-reload of config (inherited v0.2 item from the base project).

## Architecture

A **second, independent pipeline** added alongside the existing alert pipeline. It reuses the generic `Debouncer<Value>`; it does **not** use `StateMachine` (see "Why no StateMachine").

```
EXISTING (unchanged):
  NWPathMonitor ─► PathMonitor ─► Debouncer<LinkState> ─► StateMachine ─► Alerter

NEW (only when [dns_guard].enabled):
  NWPathMonitor ─► ResolverProbe ───────► Debouncer<Reachability> ─► DNSGuard.reconcile
   (interface      │  on each path change     (coalesces WG            (idempotent:
    up/down, incl.  │  + at startup, runs a     reconnect flaps,         .unreachable ⇒ clear
    WG utun appear/ │  one-shot NWConnection     then delivers the        .reachable  ⇒ restore)
    disappear)      │  TCP probe to 53)          settled verdict)              │
                    ▼                                                          ▼
          .reachable if the probe reaches .ready                /usr/sbin/networksetup -setdnsservers
          within probe_timeout, else .unreachable               (+ optional banner via /usr/bin/osascript)
```

**ResolverProbe.** Bundles the trigger and the decision. Owns an `NWPathMonitor` on an internal queue; its `pathUpdateHandler` fires on any interface/path change (WireGuard's `utun` appearing or disappearing is exactly such a change — `NWPathMonitor` is reliable for interface up/down). On each such event, and once immediately at `start()` (the seed), it runs a **one-shot active probe**: an `NWConnection` (TCP) to `known_dns:53` with a `probe_timeout_seconds` deadline. Reaching `.ready` → emit `.reachable`; failure or timeout → emit `.unreachable`; the connection is cancelled as soon as the verdict is known. Result is delivered on the target (dns) queue. Uses `Network.framework` — already imported, no new dependency. No unit test — pure network/kernel side-effect, same rationale as `PathMonitor`.

**Why an active probe (not a route or reachability check).** The only reliable signal for "can I get DNS from the Pi-hole right now" is to try it. A TCP connect to `10.3.32.102:53` is path-agnostic: it succeeds whether the Pi-hole is reached over WireGuard, over Tailscale, or directly on the LAN, and it fails when no path actually delivers packets to it. This matters on the target machine, which carries **two default routes** (`en0` Wi-Fi and `utun7` Tailscale) plus the WireGuard `utun4` — a route-egress heuristic ("is it tunnel-scoped vs default") is ambiguous under that topology, and a route-existence check (`SCNetworkReachability`) is actively wrong (v2 revision note). The probe also closes the "tunnel up but Pi-hole process dead" gap for free.

**Debouncer<Reachability>.** The existing generic `Debouncer`, reused. Rides out the flaps a WireGuard reconnect produces (several path events in quick succession): only a verdict that persists `debounce_seconds` reaches `DNSGuard`. (Consequence: a burst of path events triggers a few one-shot probes before the verdict settles — harmless, no writes; see F6 note.)

**DNSGuard.** The reconciler + action. Mirrors `Alerter`: holds its config slice and **injected side-effects** so tests record calls instead of touching the real network. `reconcile(_:)` is **idempotent** — reads the current DNS of each managed service and writes only when a change is required.

## Why no StateMachine (idempotent reconcile instead)

`StateMachine` suppresses the first event (silent seed) and fires only on transitions. Correct for *alerts* (don't scream on launch), wrong for a DNS reconciler: a daemon **launched mid-outage** (booted while away, WireGuard down, Wi-Fi still carrying a stale Pi-hole pin) must clear that pin on the seed, not wait for the next transition.

Because `reconcile` is idempotent (reads live DNS, writes only on need), running it on **every** debounced verdict — seed and steady-state included — is both simpler (one fewer component) and strictly more robust: it always converges the managed services to the desired state. Steady-state verdicts cost one cheap `-getdnsservers` read per service and no write.

## Reconciliation model (stateless, observed-value)

For each service named in `dns_guard.services`, on each debounced reachability verdict:

- **`.unreachable`** → if the service's current DNS is **exactly `[known_dns]`**, clear it (`networksetup -setdnsservers <svc> empty`).
- **`.reachable`** → if the service's current DNS is **empty**, set it to `known_dns` (`networksetup -setdnsservers <svc> <known_dns>`).

Decisions are made from **currently observed** DNS values, never remembered history. Consequences:

- **No state file.** Correct across daemon restart, crash, and mid-outage launch for free — the next verdict re-derives the right action from live state. (Honors the base project's "no persistent state" stance.)
- **Won't clobber a deliberate override.** If the user sets a managed service to `1.1.1.1`, it is neither `[known_dns]` (never cleared) nor empty (never overwritten) — DNS Guard leaves it alone in both directions.
- **Conservative match.** A service whose DNS is `[10.3.32.102, 1.1.1.1]` is not exactly `[known_dns]`, so it is not managed. DNS Guard only touches a service whose override is *exactly and only* the known DNS, or empty.
- **"Owned service" edge:** on a managed service, a manual *empty* value while reachable is re-pinned to `known_dns` (empty is the restore trigger). Listing a service in `services` means "I want `known_dns` here whenever it answers." Documented in README. (Reviewer F7: a conscious trade-off of statelessness.)

**Notification.** When `notify = true`, a banner fires via `osascript` **only if at least one service was actually mutated** in that pass — steady-state and no-op passes are silent. Down: `"Pi-hole unreachable — DNS cleared"`; up: `"Pi-hole reachable — DNS restored"`. Text is derived, not configurable in v1 (YAGNI; the alert pipeline already owns rich notifier config).

## Recovery semantics (the root tension, resolved)

Clearing the override makes macOS resolve **new** lookups via DHCP-provided DNS immediately. Names that were queried-and-failed *during* the outage may serve stale negative-cache entries until their TTL expires. Force-evicting them needs `killall -HUP mDNSResponder`, which requires **root** and would violate the project's "Don't elevate to root" invariant.

**Decision:** do **not** elevate; accept that new lookups recover immediately and stale negatives age out by TTL. No cache flush is performed. (Recovery timing was not measured — doing so requires toggling WireGuard, a live network disruption; confirm during implementation if desired.)

## Component contracts

```swift
// New, in Sources/NetSentry/

public enum Reachability: Equatable { case reachable, unreachable }

public final class ResolverProbe {
    public init(host: String, port: UInt16 = 53, timeout: TimeInterval,
                targetQueue: DispatchQueue, onResult: @escaping (Reachability) -> Void)
    public func start()   // starts NWPathMonitor; probes once immediately (seed); re-probes on each path change
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

**`DNSBackend.real.currentDNS`** runs `/usr/sbin/networksetup -getdnsservers <svc>` and **parses by IP pattern, not by the English sentinel** (reviewer S2): collect lines matching an IPv4/IPv6 literal; if none match (the empty state prints a localizable `There aren't any DNS Servers set on <svc>.`), return `[]`. Locale- and version-proof.

**Reading requires a new spawn style** (reviewer F5): `Alerter.realSpawn` is fire-and-forget with `stdout = .nullDevice`. Capturing `-getdnsservers` output needs a `Pipe` + read-to-EOF/`waitUntilExit()`, which **blocks** — acceptable only because it runs on the dedicated dns queue, never the alert queue. This is genuinely new machinery, called out as its own plan task, not folded into the existing `SpawnFn`. `setDNS` writes may stay fire-and-forget. All invocations use the absolute `/usr/sbin/networksetup` (launchd does not inherit PATH — same convention as `/usr/bin/say`).

## Config schema (TOML)

New optional section. Merged per-key over `Config.defaults`, so absent = default (honors invariant #4).

```toml
[dns_guard]
enabled = false              # opt-in; off by default
known_dns = "10.3.32.102"    # DNS server IP to probe (TCP:53) and manage
services = ["Wi-Fi"]         # network service(s) whose DNS override DNS Guard owns
debounce_seconds = 3.0       # coalesce path-change bursts / ride out WG reconnect flaps before acting
probe_timeout_seconds = 2.0  # TCP:53 probe deadline; miss ⇒ known_dns treated as unreachable
notify = true                # banner when it clears / restores
```

Repo-shipped defaults stay generic so the public repo carries no personal data:

```swift
public struct DNSGuard: Equatable {
    public var enabled: Bool             // false
    public var knownDNS: String          // ""   → if enabled with empty knownDNS, log a warning and run as no-op
    public var services: [String]        // ["Wi-Fi"]
    public var debounceSeconds: Double    // 3.0
    public var probeTimeoutSeconds: Double // 2.0
    public var notify: Bool              // true
}
```

The author's real values live only in `~/Library/Application Support/net-sentry/config.toml`. `config.example.toml` shows the section with a commented, illustrative `known_dns`.

## Privilege model

A `networksetup -setdnsservers` write run in an interactive shell by the (admin-group) user returned exit 0 with no sudo/prompt. **This is necessary but not sufficient evidence** (reviewer S4): the daemon runs **non-interactively under launchd** (`gui/$(id -u)` domain), where authorization for `system.services.systemconfiguration.network` can differ (admin authorization-DB defaults, the "require admin password for system-wide preferences" setting).

**Implementation gate:** before the feature is considered working, confirm a real `-setdnsservers` write succeeds from inside the installed LaunchAgent — e.g. a debug one-shot at daemon startup whose exit status is checked in `~/Library/Logs/net-sentry.err.log`. Not verifiable until a daemon exists to run it. The feature still runs in the same user LaunchAgent as the alerter (no root, no LaunchDaemon split), upholding the "Don't elevate to root" invariant; the standard-user case stays out of scope.

## Concurrency

The new pipeline runs on its own serial queue `link.smirnov.net-sentry.dns`. The two pipelines share **no mutable state** — separate monitors, separate debouncer instances, and `DNSGuard` keeps no state (it reads live DNS each pass). So no locking across pipelines, and a blocking `networksetup` read/write on the dns queue never delays the alert pipeline's speech/modal/banner. The `NWConnection` probe runs async on the dns queue; its completion hops back to the dns queue before `reconcile`.

## Wiring (main.swift)

Added after the existing pipeline, only when `config.dnsGuard.enabled` and `known_dns` is non-empty.

**Lifetime:** `main.swift` is top-level script code, so the pipeline refs must be bound at top-level scope — bindings inside an `if { … }` block are deallocated at the block's close, tearing down the `NWPathMonitor`/`NWConnection` before `dispatchMain()`. The base daemon relies on `let monitor = …` being top-level for exactly this reason. Hold the new chain in a top-level `var` (reviewer F8 confirmed this is correct):

```swift
var dnsPipeline: [AnyObject] = []            // top-level: retains the chain for the process lifetime
if config.dnsGuard.enabled, !config.dnsGuard.knownDNS.isEmpty {
    let dnsQueue = DispatchQueue(label: "link.smirnov.net-sentry.dns")
    let dnsGuard = DNSGuard(config: config.dnsGuard)          // reads config.notify internally
    let dnsDebouncer = Debouncer<Reachability>(
        window: .milliseconds(Int(config.dnsGuard.debounceSeconds * 1000)),
        queue: dnsQueue) { [dnsGuard] r in dnsGuard.reconcile(r) }
    let probe = ResolverProbe(host: config.dnsGuard.knownDNS, port: 53,
                              timeout: config.dnsGuard.probeTimeoutSeconds,
                              targetQueue: dnsQueue) { [dnsDebouncer] r in dnsDebouncer.submit(r) }
    probe.start()                                            // emits an immediate seed probe
    dnsPipeline = [dnsGuard, dnsDebouncer, probe]            // keep-alive
} else if config.dnsGuard.enabled {
    FileHandle.standardError.write(Data("net-sentry: dns_guard enabled but known_dns is empty; skipping\n".utf8))
}
```

## File layout delta

```
Sources/NetSentry/ResolverProbe.swift         # new — NWPathMonitor trigger + one-shot TCP:53 NWConnection probe
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

No change to `Package.swift` — `Network.framework` (and `Foundation`) are system frameworks, imported directly, no SwiftPM dependency.

## New invariant (add to CLAUDE.md)

> **DNS Guard probes and reconciles on the seed.** `ResolverProbe` runs an immediate probe at `start()`, and `DNSGuard.reconcile` runs on the first (debounced) verdict — unlike the alert `StateMachine`'s silent first-event seed — so a daemon launched mid-outage clears a stale pin immediately. Safe because `reconcile` is idempotent (reads live DNS, writes only on need). Do not "optimize" it into transition-only firing.

## Error handling

| Failure mode | Behavior |
|---|---|
| Probe reaches `.ready` | `.reachable` |
| Probe fails or exceeds `probe_timeout_seconds` | `.unreachable` (connection cancelled) |
| `NWConnection` cannot even be created (bad host string, etc.) | Logged to stderr; **no** verdict emitted (inconclusive — must not clear on internal error) |
| `networksetup` read returns unexpected/unparseable text | No IP lines parsed → treated as empty only if truly no IPs; genuinely malformed → leave service untouched, log |
| `networksetup` set returns non-zero | Logged to stderr; daemon continues (next verdict retries from live state) |
| `[dns_guard].enabled = true` but `known_dns = ""` | Warning to stderr; pipeline not started (no-op) |
| Config missing/malformed `[dns_guard]` | Per-key merge over defaults → section absent means `enabled=false` → feature off |
| Daemon crash mid-outage | launchd `KeepAlive` respawns; seed probe + reconcile re-derive correct action from live DNS |

## Testing (strict TDD)

`DNSGuard` is unit-tested through an injected `DNSBackend` recorder + `SpawnFn` recorder:

1. `.unreachable` + service DNS `== [known_dns]` → one `setDNS(svc, [])`; notify banner recorded.
2. `.unreachable` + service DNS `== [1.1.1.1]` → no `setDNS`; no banner.
3. `.reachable` + service DNS empty → one `setDNS(svc, [known_dns])`; banner.
4. `.reachable` + service DNS `== [1.1.1.1]` → no write; no banner.
5. `.reachable` + service already `== [known_dns]` → no write; no banner (idempotent steady state).
6. Multiple `services` → each evaluated independently.
7. `notify = false` → never spawns a banner even when mutating.
8. Idempotence: two identical verdicts → writes only on the first.
9. `DNSBackend.real` parse: IP lines → `[servers]`; the empty-state sentinel (and a localized variant) → `[]`.

`ResolverProbe` has no unit test (NWPathMonitor callback + live socket, same rationale as `PathMonitor`). `ConfigLoaderTests` gains `[dns_guard]` parse + partial-section + absent-section cases; `ConfigDefaultsTests` asserts the new defaults.

**Manual E2E** (during install verification):

1. Smoke: `enabled=false` default build behaves exactly as before (no second pipeline).
2. **Privilege gate (S4):** with the daemon installed and running, confirm a `-setdnsservers` write from its launchd context succeeds (check logs).
3. Enable with `known_dns=10.3.32.102`, `services=["Wi-Fi"]`; confirm Wi-Fi currently `== 10.3.32.102`.
4. Bring WireGuard down. Within ~`debounce + probe_timeout + 1`s: Wi-Fi DNS cleared (`networksetup -getdnsservers Wi-Fi` → empty), **new** DNS lookups resolve again, banner shown.
5. Bring WireGuard back up. Within the same window: Wi-Fi DNS re-pinned to `10.3.32.102`, banner shown.
6. Flap test: toggle WireGuard off/on within the debounce window → no DNS change.
7. Override test: set Wi-Fi to `1.1.1.1`, drop WireGuard → unchanged (not managed).
8. Mid-outage launch: with WireGuard down and Wi-Fi pinned, `launchctl kickstart -k` the daemon → Wi-Fi cleared on the seed probe.

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

`Config.DNSGuard` becomes `{ enabled, debounce_seconds, probe_timeout_seconds, notify, watches: [Watch] }`; the loader reads the table-array; `main` spins one `ResolverProbe`+`Debouncer`+`DNSGuard` per watch on the shared dns queue. Auto-detect of services (drop the explicit list) is the other extension; it requires remembering the managed set, so it is deferred with that cost noted. Both documented in `CLAUDE.md` "Common tasks".

## Limitations (v1)

- **Wakes on `NWPathMonitor` events.** A known-DNS failure that produces no interface/path change would go unnoticed until the next path event. WireGuard up/down *is* an interface change, so the target scenario is covered; a silent Pi-hole death with no routing change would be caught only on the next unrelated path event (or daemon restart).
- **Recovery lag for stale negatives.** New lookups recover immediately on clear; names cached-negative during the outage age out by TTL. No root cache-flush (see Recovery semantics).
- **Admin user required** for the password-free `networksetup` write, and must be confirmed from the launchd context (S4).
- **Exact-match management only** — a service mixing `known_dns` with other resolvers is left untouched by design.
