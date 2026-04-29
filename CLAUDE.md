# CLAUDE.md

Guidance for Claude Code (or any AI agent) working on this repo.

## Project overview

`net-sentry` is a single-purpose macOS daemon written in Swift. It detects internet connectivity loss via Apple's `NWPathMonitor` (Network framework) and fires multi-channel alerts (speech via `say`, modal via `osascript display dialog`, notification banner via `osascript display notification`). All alert behavior is configured via TOML; embedded defaults are used if the file is missing or malformed. The daemon runs continuously as a launchd LaunchAgent with `KeepAlive: true`.

The codebase is intentionally tiny — ~290 LOC of library code, ~290 LOC of tests, single runtime dependency (TOMLKit). **Don't grow it without strong reason.** The design philosophy is "do one thing, ship it, keep it small."

## Architecture

```
NWPathMonitor (kernel events) → PathMonitor → Debouncer → StateMachine → Alerter
                                                                            ↓
                                            3 parallel fire-and-forget Process() spawns:
                                            • /usr/bin/say
                                            • /usr/bin/osascript (display dialog — modal)
                                            • /usr/bin/osascript (display notification — banner)
```

A single serial `DispatchQueue` named `link.smirnov.net-sentry.state` owns all state mutation. PathMonitor's callback hops onto this queue before touching any state, so there's **no locking and no race conditions**.

Subprocess spawns from Alerter are async (fire-and-forget via `Process().run()` without `waitUntilExit`). This is intentional: a slow `osascript display dialog` MUST NOT block the speech or banner from firing.

## File responsibility map

| File | Responsibility | Tests |
|---|---|---|
| `Sources/NetSentry/Config.swift` | `Config` struct + `Config.defaults` static. Pure data, no logic. | `ConfigDefaultsTests.swift` |
| `Sources/NetSentry/ConfigLoader.swift` | Parses TOML → `Config`, merging over defaults per-key. **Never throws** — returns defaults on missing/malformed file. | `ConfigLoaderTests.swift` (4 paths) |
| `Sources/NetSentry/Debouncer.swift` | Generic `Debouncer<Value>` with cancel-and-reschedule semantics via `DispatchWorkItem`. | `DebouncerTests.swift` |
| `Sources/NetSentry/StateMachine.swift` | `LinkState` (`.online`/`.offline`), `Transition` (`.up`/`.down`). Silent first-event seed; transitions only. | `StateMachineTests.swift` |
| `Sources/NetSentry/Alerter.swift` | Reads `[notifiers.*]` config, dispatches subprocess via injected `SpawnFn`. AppleScript escaping for backslash + quote. | `AlerterTests.swift` |
| `Sources/NetSentry/PathMonitor.swift` | Thin wrapper around `NWPathMonitor`; emits `LinkState` on the target queue. | _Integration test only — kernel callback can't be unit-tested._ |
| `Sources/net-sentry-cli/main.swift` | Wires everything; runs `dispatchMain()`. | _End-to-end manual test._ |

Tests are parallel to source files, one per testable component.

## Build & test

```bash
swift build                  # debug build
swift build -c release       # release build (used by install.sh)
swift test                   # 21 unit tests, <1s total
swift test --filter Foo      # run a specific suite (e.g. AlerterTests)
.build/debug/net-sentry      # foreground run for log inspection (Ctrl-C to exit)
```

Tests are fast (<1s total) and self-contained. No file-system fixtures beyond per-test temp dirs (which are torn down in `tearDown`).

## Install / uninstall

```bash
./install.sh    # builds release, installs binary, seeds config, bootstraps LaunchAgent
./uninstall.sh  # bootouts LaunchAgent, removes binary; PRESERVES config + logs
```

Both scripts are idempotent. Re-running `install.sh` on a system that already has the daemon running will:
1. Rebuild the binary (incremental, fast)
2. Refresh the binary at `~/.local/bin/`
3. **Skip** seeding config if `config.toml` already exists (preserves user edits)
4. `launchctl bootout` (always safe — no-ops if not loaded) followed by `launchctl bootstrap`

After config edits, reload the daemon with `launchctl kickstart -k "gui/$(id -u)/link.smirnov.net-sentry"` — this is faster than uninstall+reinstall and preserves the launchd registration.

## Code conventions

- **Strict TDD on testable components.** Write a failing test first, watch it fail, then implement. The implementation plan in `docs/superpowers/plans/` enforces this step-by-step.
- **All public types in the `NetSentry` library are `public`.** The library has no internal-only abstraction layers. Tests use `@testable import NetSentry`, but the actual public surface is the same as what `net-sentry-cli` consumes.
- **`Equatable` on data types** where it aids test ergonomics (Config, ConfigLoadResult, ConfigDiagnostic, Transition, LinkState, SpawnCall).
- **`try?` to swallow expected errors** (e.g., subprocess spawn failures); **`do/catch` when the error info is needed** (e.g., TOML parse error → diagnostic message).
- **Subprocess invocation in tests is NEVER real.** Inject a recorder closure via `SpawnFn`. Production callers use `Alerter.realSpawn`.
- **Don't add error handling for cases that can't happen.** Trust framework guarantees. Validate at boundaries (config file, kernel events) only.
- **Comments are rare** — only when the *why* is non-obvious. The fire-and-forget `try? p.run()` in `Alerter.swift` and the backslash-first ordering in `escapeForAppleScript` are documented exceptions.

## Key invariants — DO NOT BREAK

These are load-bearing design decisions. Changing them requires re-reading the spec.

1. **Silent first-event seed in StateMachine.** When net-sentry launches, the very first NWPathMonitor callback seeds state without firing any alert. Otherwise, launching while offline would scream immediately at the user. The `current: LinkState?` field starts `nil` and is only assigned after the first event.

2. **Transition-only alerts.** Steady-state events (`.online → .online`, `.offline → .offline`) are silent. NWPathMonitor sometimes emits same-state events when the underlying interface changes (Wi-Fi → Ethernet failover keeps you online but emits an event).

3. **Fire-and-forget subprocess spawn.** The Alerter MUST NOT call `waitUntilExit()`. A slow `osascript display dialog` (which blocks until user clicks OK) would otherwise block speech and banner from firing in parallel.

4. **Default-on-missing config keys.** Adding a new TOML key in a future version must not break existing installations. ConfigLoader merges over `Config.defaults` per-key — present keys override, absent keys are left at default.

5. **Empty-string `text_*` = skip channel for that direction.** This is the documented sentinel for asymmetric configurations like "speech on down only, banner on both directions." Tests cover this in `AlerterTests.testUpFiresOnlyBannerByDefault`.

6. **AppleScript escape order: backslash first, then quote.** If quote ran first, you'd double-escape the backslashes you introduced. Tested in `AlerterTests.testAppleScriptEscapesBackslashAndQuote`.

7. **`__HOME__` placeholder in the plist.** `install.sh` substitutes `__HOME__` with `$HOME` via `sed`, which works correctly even on systems where home directories aren't at `/Users/<name>`. Don't hardcode the path.

## Common tasks

### Add a new notifier channel (e.g., webhook)

1. Add a new struct under `Config.Notifiers` with whatever fields it needs (URL, method, etc.) — mirror the shape of `Speech`/`Modal`/`Banner`.
2. Add a default value in `Config.defaults`.
3. Extend `ConfigLoader.merge` to read the new TOML section.
4. Add a new branch in `Alerter.fire` that constructs a `SpawnCall` for the new channel (e.g., `/usr/bin/curl -X POST <url>` for webhooks).
5. Add tests in `AlerterTests` for the new dispatch logic — both "fires when configured" and "skipped when disabled or empty text."
6. Document the new section in `config.example.toml`.

### Change the debounce window default

1. Edit `Config.defaults.debounce.seconds` in `Config.swift`.
2. Update `ConfigDefaultsTests.testDefaultsHaveSaneValues` to match.
3. Update `config.example.toml` to match.

### Change the alert text

User-facing concern. Edit `~/Library/Application Support/net-sentry/config.toml` directly — no recompile. After editing, run:

```bash
launchctl kickstart -k "gui/$(id -u)/link.smirnov.net-sentry"
```

The plan deliberately doesn't include hot-reload of config — it's a v0.2 enhancement.

### Add a captive-portal probe

Listed under `Limitations` in the spec as v0.2 work. The hook is in `StateMachine` after the `.satisfied` transition: before calling `onTransition(.up)`, kick off an async probe to `http://captive.apple.com/hotspot-detect.html` and only fire the recovery alert if the response body contains the expected `<TITLE>Success</TITLE>` string.

## Where things live (post-install)

| Concern | Location |
|---|---|
| Source | `Sources/NetSentry/`, `Sources/net-sentry-cli/` |
| Tests | `Tests/NetSentryTests/` |
| Installed binary | `~/.local/bin/net-sentry` |
| LaunchAgent plist (instantiated) | `~/Library/LaunchAgents/link.smirnov.net-sentry.plist` |
| User config | `~/Library/Application Support/net-sentry/config.toml` |
| Daemon stdout log | `~/Library/Logs/net-sentry.out.log` |
| Daemon stderr log | `~/Library/Logs/net-sentry.err.log` |
| Design spec (frozen) | `docs/superpowers/specs/2026-04-29-net-sentry-design.md` |
| Implementation plan (executed) | `docs/superpowers/plans/2026-04-29-net-sentry-implementation.md` |

## Don't

- **Don't add polling.** The whole point is event-driven detection via NWPathMonitor.
- **Don't `waitUntilExit()`** on the Alerter's subprocesses.
- **Don't make config keys required.** Always merge over `Config.defaults` so old configs keep working.
- **Don't introduce a second runtime dependency** without explicit reason. TOMLKit is the line.
- **Don't restructure into multiple Swift modules.** The single-library + tiny-executable layout is deliberate. If you find yourself wanting more modules, you're probably overgrowing the project.
- **Don't add `--help`/`--version` flags** unless asked. The daemon has one job; CLI args would be over-engineering.
- **Don't add telemetry, analytics, crash reporting, or auto-update.** Not ever.
- **Don't elevate to root.** The daemon runs as the user's LaunchAgent (gui domain), which is sufficient for `say` and `osascript`. Running as root would actually break the GUI rendering.

## Test philosophy

- **Tests verify behavior, not implementation.** A test that breaks when you refactor without changing behavior is a bad test.
- **Inject side effects.** The Alerter takes a `SpawnFn` so tests record calls instead of actually running subprocesses. PathMonitor doesn't have unit tests because it's pure side effect (kernel callback).
- **Use temp directories for file-system tests.** `ConfigLoaderTests` creates a unique-UUID temp dir per test and tears it down afterward — no shared state, no parallel-test collisions.
- **Don't mock what you don't own.** No mocks for `NWPathMonitor`, `Process`, or `FileManager`. The Alerter's `SpawnFn` injection is owned by us; everything else is exercised against real APIs (or temp directories).

## Reference: original implementation arc

This repo was built from scratch in a single afternoon using a structured AI-assisted workflow:

1. **Diagnose** — interactive shell session investigated the original Wi-Fi outage that motivated the project.
2. **Brainstorm** — the [`superpowers:brainstorming`](https://github.com/anthropics/claude-code) skill explored the design space (detection level, alert channels, debounce semantics, config format).
3. **Spec** — the design was written to `docs/superpowers/specs/2026-04-29-net-sentry-design.md` and committed before any code.
4. **Plan** — a 12-task implementation plan was written to `docs/superpowers/plans/2026-04-29-net-sentry-implementation.md`, with each task containing the full code, test, and commit message.
5. **Execute** — each task was implemented via a fresh subagent following strict TDD, with two-stage review (spec compliance + code quality) on the substantive tasks.

The full conversation, design rationale, and review findings are preserved in the docs/ directory if you want to study the workflow that produced this. The most interesting commits to look at:

- `7103d01` — initial design spec (the contract)
- `c578396` — implementation plan (the executable recipe)
- `5a7ce7a` — bug fix from code review (caught a silent AppleScript-escape failure mode)
- `41a20dc` — final feature-branch commit (tagged as v0.1.0)
