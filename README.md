# net-sentry

**A tiny macOS daemon that loudly tells you when the internet drops.**

![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange.svg)
![Platform: macOS 12+](https://img.shields.io/badge/Platform-macOS%2012%2B-blue.svg)
![Apple Silicon](https://img.shields.io/badge/CPU-Apple%20Silicon-green.svg)

> _"I was voice-dictating a long passage. Wi-Fi died silently mid-sentence. I kept talking for two minutes into a void before I noticed."_

That's the failure mode net-sentry exists to prevent. When your network goes down, three things happen at once:

- Your Mac **speaks "Internet is down"** through the speakers — cuts through dictation
- A **modal dialog** appears centered on your screen
- A **notification banner** slides in from the top-right

When the network recovers, you get a quiet banner — _"Internet is back"_ — and nothing else. **Loud on the way down, quiet on the way up.**

---

## Why this exists

Voice dictation occupies your audio *input*. macOS's stock "no internet" globe in the menu bar is silent and visual-only — easy to miss when you're not staring at the screen. net-sentry uses your **audio output**, **focus interrupt**, and **passive notification** channels in parallel to be impossible to miss.

It was built after exactly the dictation outage in the quote above, in a single afternoon.

## Features

- **Zero polling.** Built on Apple's `NWPathMonitor` — the same kernel-event-driven API Safari and Mail use to know whether there's a path to the internet. Wakes only when the kernel reports a state change.
- **Smart debounce.** Wi-Fi roams between APs cause brief (200–800 ms) "no path" blips even on healthy networks. A 2-second debounce window suppresses those without delaying real outages meaningfully.
- **Editable everything.** Voice, alert text, debounce window, which channels are on, modal timeout — all in a single TOML file. No recompile.
- **Self-healing.** Runs as a launchd LaunchAgent with `KeepAlive: true`. If the daemon crashes for any reason, launchd respawns it within seconds.
- **Tiny.** ~290 lines of Swift, one runtime dependency (TOMLKit), single-file binary, ~300 KB compiled. No menu-bar app, no preference pane, no telemetry, no analytics, no auto-updater.
- **Zero CPU at rest.** Sits in `dispatchMain()` waiting for kernel events. `top` reports 0.0% CPU.

## Install

### Via Homebrew (recommended)

```bash
brew tap issmirnov/apps
brew install net-sentry
brew services start net-sentry
```

### From source

```bash
git clone https://github.com/issmirnov/net-sentry.git
cd net-sentry
./install.sh
```

The bundled `install.sh` script:
1. Builds the binary in release mode
2. Copies it to `~/.local/bin/net-sentry`
3. Seeds a config at `~/Library/Application Support/net-sentry/config.toml` (only if you don't already have one)
4. Registers a launchd LaunchAgent so the daemon starts on every login

**Test it:** turn off Wi-Fi from the menu bar. Within ~2 seconds, you'll get speech + modal + banner. Turn Wi-Fi back on. Within ~2 seconds, you'll get a quiet "Internet is back" banner.

## Configure

Edit `~/Library/Application Support/net-sentry/config.toml`:

```toml
[debounce]
seconds = 2.0                # how long unsatisfied must persist before alerting

[notifiers.speech]
enabled = true
voice = "Samantha"           # `say -v ?` for the full list
text_down = "Internet is down"
text_up = ""                 # empty = skip recovery direction

[notifiers.modal]
enabled = true
icon = "stop"                # stop | caution | note
timeout_seconds = 30         # auto-dismiss; 0 = block forever
text_down = "Internet is down"
text_up = ""

[notifiers.banner]
enabled = true
title = "Net Sentry"
text_down = "Internet is down"
text_up = "Internet is back"
```

After editing, reload the daemon:

```bash
launchctl kickstart -k "gui/$(id -u)/link.smirnov.net-sentry"
```

### Common tweaks

| Goal | Edit |
|---|---|
| **Disable the modal popup** (keep voice + banner) | `[notifiers.modal] enabled = false` |
| **Use a different voice** | `[notifiers.speech] voice = "Alex"` (or any from `say -v ?`) |
| **Be louder on recovery too** | `[notifiers.speech] text_up = "Internet is back"` |
| **Tolerate flakier networks** | `[debounce] seconds = 5.0` |
| **Silent monitoring** (daemon runs but doesn't alert) | All `enabled = false` |
| **Block forever on the modal** (until user clicks OK) | `[notifiers.modal] timeout_seconds = 0` |

Empty-string `text_*` is the sentinel for "skip this direction for this channel" — that's why the default `text_up = ""` for speech and modal means recovery is banner-only.

## How it works

```
NWPathMonitor (kernel events, ~50 ms latency, zero polling)
      ↓
PathMonitor (Swift wrapper; hops onto the state queue)
      ↓
Debouncer (2-second cancel-and-reschedule window)
      ↓
StateMachine (online/offline; transitions only; silent first-event seed)
      ↓
Alerter (3 parallel Process() spawns)
      ↓                ↓                       ↓
  /usr/bin/say     /usr/bin/osascript     /usr/bin/osascript
   (speech)         (display dialog)       (display notification)
```

A single serial `DispatchQueue` (`link.smirnov.net-sentry.state`) owns all state mutation, so there's no locking and no race conditions. The Alerter spawns subprocesses fire-and-forget via `Process().run()` without `waitUntilExit()`, so a slow modal can't delay the speech or banner from firing.

The Alerter's subprocess invocation is **injected as a closure** so unit tests record calls instead of actually running `say`/`osascript`. Production code passes `Alerter.realSpawn`; tests pass a recorder.

## Why not just…

- **…use macOS's stock "no internet" globe in the menu bar?** Silent and visual-only. Useless when you're voice-dictating and not looking at the screen.
- **…use a polling shell script with `ping`?** Polling has a fundamental tradeoff: low interval = wasted CPU/battery; high interval = late alerts. Event-driven detection has neither problem.
- **…use a third-party menu-bar app?** Bigger, slower, telemetry-laden, often not configurable below the GUI surface. net-sentry is one Swift file, one launchd plist, one TOML config.
- **…just configure macOS Notifications to be more aggressive?** macOS doesn't expose Wi-Fi state changes as automation hooks for arbitrary user scripts.
- **…sell the daemon as a Mac App Store app?** App Store sandboxing makes the launchd-LaunchAgent + system-level subprocess invocation pattern impossible. This is intentionally a CLI utility.

## Limitations (v0.1)

- **macOS only.** Built on Apple's `NWPathMonitor` (Network framework).
- **No captive-portal detection.** If you're behind a hotel/airport sign-in page, `NWPathMonitor` reports `.satisfied` but you can't actually reach the internet. Net-sentry won't alert in that scenario. _(Fix would be a one-shot `captive.apple.com` probe on every `.satisfied` transition. Planned for v0.2.)_
- **No hot-reload of config.** Edits require `launchctl kickstart -k`. _(Trivial to add via `DispatchSourceFileSystemObject`. Planned for v0.2.)_

## Development

```bash
swift build                  # debug build
swift build -c release       # release build (this is what install.sh uses)
swift test                   # 21 unit tests, <1s total
.build/debug/net-sentry      # run in foreground (for log inspection)
```

The codebase splits into:

- **`Sources/NetSentry/`** — library target with the testable components (Config, ConfigLoader, Debouncer, StateMachine, Alerter, PathMonitor)
- **`Sources/net-sentry-cli/`** — thin executable that wires them together and runs `dispatchMain()`
- **`Tests/NetSentryTests/`** — XCTest cases parallel to the source files

See [`docs/superpowers/specs/2026-04-29-net-sentry-design.md`](docs/superpowers/specs/2026-04-29-net-sentry-design.md) for the full design rationale and [`docs/superpowers/plans/2026-04-29-net-sentry-implementation.md`](docs/superpowers/plans/2026-04-29-net-sentry-implementation.md) for the task-by-task implementation plan that built this from scratch.

If you're a Claude Code agent looking to extend this project, read [`CLAUDE.md`](CLAUDE.md) first.

## Uninstall

If installed via Homebrew:

```bash
brew services stop net-sentry
brew uninstall net-sentry
```

If installed from source:

```bash
./uninstall.sh
```

Either way, your config and logs are **preserved** so reinstalling doesn't clobber edits.

## License

[MIT](LICENSE) — do whatever you want with it.

## Acknowledgments

Built with [TOMLKit](https://github.com/LebJe/TOMLKit) for human-friendly config parsing, and Apple's `Network.framework` for kernel-event-driven path monitoring.

Designed and implemented with [Claude Code](https://claude.com/claude-code) in a single afternoon — design spec, task-by-task TDD plan, and execution all preserved in the `docs/` directory if you're curious about the AI-assisted workflow that produced it.
