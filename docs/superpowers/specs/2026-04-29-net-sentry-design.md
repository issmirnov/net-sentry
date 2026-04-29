# net-sentry — Design

**Status:** Approved 2026-04-29
**Last updated:** 2026-04-29

## Problem

Voice dictation on macOS continues silently when Wi-Fi drops, losing minutes of speech-to-text work with no signal to the user. The user is typically not looking at the screen during dictation, so a passive notification banner is insufficient. We need a small, always-running utility that detects connectivity loss via OS event hooks (no polling) and alerts loudly enough to interrupt dictation through a non-visual channel.

## Goals

- Detect internet connectivity loss within ~2 seconds of the actual outage.
- Alert through audio + modal + notification simultaneously when going offline (multi-channel for the eyes-off-screen case).
- Notify quietly on recovery (banner only).
- Run continuously as a background daemon, autostarting at login.
- All alert behavior (text, voice, channels, debounce) configured via human-editable TOML — no hardcoded strings.
- Tiny: single Swift binary, single dependency (TOMLKit), under ~150 LOC of source.

## Non-goals

- Probing specific services (e.g. "is Slack reachable") — would require polling, out of scope.
- Cross-platform support — macOS only.
- GUI for configuration — TOML file is the UI.
- Persistent log/history of outages — `Console.app` reading the launchd stdout/stderr is sufficient.
- Hot-reload of config — edits require a daemon restart in v1.

## Architecture

Single Swift CLI process driven by Apple's `NWPathMonitor`. Three internal components plus a config loader:

```
                   ┌──────────────────┐
                   │  ConfigLoader    │
                   │  (TOML → struct) │
                   └────────┬─────────┘
                            │ (config struct)
                            ▼
NWPathMonitor ──► PathMonitor ──► Debouncer ──► StateMachine ──► Alerter
   (kernel)      (callback hop)   (2s timer)   (transitions)    (3 channels)
                                                                     │
                                                              ┌──────┼──────┐
                                                              ▼      ▼      ▼
                                                            say  osascript osascript
                                                                  (modal)  (banner)
```

**PathMonitor.** Owns the `NWPathMonitor` instance. Its `pathUpdateHandler` hops onto the serial state queue and forwards the new `NWPath.Status`.

**Debouncer.** Uses `DispatchWorkItem.cancel()` + `DispatchQueue.asyncAfter`. Each new path event cancels the pending work item and schedules a fresh one for `config.debounce.seconds` later. Only if the debounce window elapses without contradiction does the work item fire and call into the state machine.

**StateMachine.** Holds `enum State { .online, .offline }`. Fires `Alerter.fire(.down)` only on `.online → .offline`; `Alerter.fire(.up)` only on `.offline → .online`. Steady-state events are silent. The very first event after startup seeds the state without firing any alert (avoids "you launched offline → screams immediately").

**Alerter.** Reads the `[notifiers.*]` config sections. For each notifier with `enabled = true` and a non-empty `text_<direction>`, spawns the appropriate shell-out via `Process()`. All notifiers fire concurrently (not serially) so the modal does not block speech.

**ConfigLoader.** Reads `~/Library/Application Support/net-sentry/config.toml` at startup. Falls back to embedded defaults if the file is missing. On malformed TOML, logs a warning to stderr and uses defaults — does **not** crash, to avoid a launchd respawn loop on a bad edit.

## Concurrency model

A single serial `DispatchQueue` named `link.smirnov.net-sentry.state` owns all state mutation. NWPathMonitor's callback hops onto this queue before touching state, so:

- No locking required.
- No race between debouncer firing and a new event arriving.
- Predictable serialization order.

The `Alerter` shell-outs are launched OFF the state queue (via `Process().run()`, which returns immediately after spawn), so a slow `osascript` modal cannot block subsequent path events.

## Detection mechanism — why NWPathMonitor

`NWPathMonitor` is Apple's modern, kernel-event-driven API for path satisfiability. It fires within ~50 ms of a real link change with zero polling overhead, and is the same signal `NSURLSession`, Safari, and the Wi-Fi menu's "no internet" globe icon use internally.

Detection level chosen: **path satisfiability** (`NWPath.status == .satisfied | .unsatisfied`), not just link/IP loss. This catches Wi-Fi disassociation, default-route loss, and any other case where the kernel believes there is no usable path to the internet.

## Debounce — why 2 seconds

Wi-Fi roams between APs cause brief (200–800 ms) `.unsatisfied` blips even on healthy networks. A 2-second window:

- Suppresses all observed roam-induced false positives.
- Is short enough that the alert fires while you've spoken at most ~1 sentence into a dropped dictation.
- Is configurable via `[debounce] seconds` for users with stricter requirements.

The asymmetry of cost is deliberate: a false alert costs ~1 second of attention, a missed alert costs minutes of lost dictation. When in doubt, lean toward firing.

## Config schema (TOML)

Path: `~/Library/Application Support/net-sentry/config.toml`

```toml
[debounce]
seconds = 2.0

[notifiers.speech]
enabled = true
voice = "Samantha"            # `say -v ?` for the full list
text_down = "Internet is down"
text_up = ""                  # empty = skip this direction

[notifiers.modal]
enabled = true
icon = "stop"                 # stop | caution | note
timeout_seconds = 30          # auto-dismiss; 0 = block forever
text_down = "Internet is down"
text_up = ""

[notifiers.banner]
enabled = true
title = "Net Sentry"
text_down = "Internet is down"
text_up = "Internet is back"
```

**Conventions:**

- Empty-string `text_*` means "skip this direction for this channel."
- Every key has a built-in default in code, so a missing config file is fine and a partial config file is fine.
- `enabled = false` short-circuits the entire channel for both directions.

## Alert channel implementations

All shell-outs use absolute paths (PATH may not be inherited in the launchd context):

```
DOWN (parallel — all three spawned without waiting):
  /usr/bin/say -v <voice> "<text_down>"
  /usr/bin/osascript -e 'display dialog "<text_down>" with icon <icon>
                         buttons {"OK"} default button "OK"
                         giving up after <timeout_seconds>'
  /usr/bin/osascript -e 'display notification "<text_down>" with title "<title>"'

UP (parallel):
  same three with text_up; any with empty text_up are skipped
```

If `timeout_seconds = 0`, the modal blocks until manually dismissed (rarely useful, but supported).

## Autostart — launchd LaunchAgent

`~/Library/LaunchAgents/link.smirnov.net-sentry.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>            <string>link.smirnov.net-sentry</string>
    <key>ProgramArguments</key> <array><string>__HOME__/.local/bin/net-sentry</string></array>
    <key>RunAtLoad</key>         <true/>
    <key>KeepAlive</key>         <true/>
    <key>ProcessType</key>       <string>Background</string>
    <key>StandardOutPath</key>   <string>__HOME__/Library/Logs/net-sentry.out.log</string>
    <key>StandardErrorPath</key> <string>__HOME__/Library/Logs/net-sentry.err.log</string>
</dict>
</plist>
```

`__HOME__` placeholder is rewritten with `$HOME` by `install.sh` so the plist is portable across machines and accounts for non-`/Users/<name>` home paths.

Loaded with `launchctl bootstrap gui/$(id -u) <plist>` (modern API; required for the GUI domain so notifications and modals can render). The legacy `launchctl load` form is deprecated and can silently miss the GUI session.

## File layout

```
~/Projects/1.Personal/net-sentry/
  Package.swift                            # SwiftPM manifest; one dep: TOMLKit
  Sources/net-sentry/main.swift            # all code (~120 LOC)
  config.example.toml                      # ships with sane defaults
  link.smirnov.net-sentry.plist            # launchd template (with __USER__ placeholder)
  install.sh                               # build → install binary → seed config → bootstrap LaunchAgent
  uninstall.sh                             # bootout LaunchAgent → rm binary (preserves config)
  docs/
    superpowers/
      specs/
        2026-04-29-net-sentry-design.md   # this file
  README.md
  .gitignore                               # .build, .swiftpm, .DS_Store
```

## install.sh behavior (sketch)

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

install -d "$HOME/.local/bin"
install .build/release/net-sentry "$HOME/.local/bin/net-sentry"

CONFIG_DIR="$HOME/Library/Application Support/net-sentry"
install -d "$CONFIG_DIR"
[ -f "$CONFIG_DIR/config.toml" ] || cp config.example.toml "$CONFIG_DIR/config.toml"

install -d "$HOME/Library/Logs"
install -d "$HOME/Library/LaunchAgents"
sed "s|__HOME__|$HOME|g" link.smirnov.net-sentry.plist \
    > "$HOME/Library/LaunchAgents/link.smirnov.net-sentry.plist"

launchctl bootout  gui/$(id -u)/link.smirnov.net-sentry 2>/dev/null || true
launchctl bootstrap gui/$(id -u) "$HOME/Library/LaunchAgents/link.smirnov.net-sentry.plist"

echo "net-sentry installed and running."
```

`uninstall.sh` is the symmetric inverse, except it does NOT delete `~/Library/Application Support/net-sentry/config.toml` — user edits are preserved across reinstalls.

## Error handling

| Failure mode | Behavior |
|---|---|
| `Process()` shell-out returns non-zero (e.g. `osascript` errors) | Logged to stderr; daemon continues |
| TOML config file is malformed | Warning to stderr; daemon falls back to embedded defaults; keeps running |
| TOML config file is missing | Silent fallback to embedded defaults |
| Unhandled Swift error / crash | Process exits; launchd `KeepAlive: true` respawns within seconds |
| `launchctl bootstrap` collides with existing load | `install.sh` runs `bootout` first to ensure idempotency |

## Testing

Manual, executed in order during install verification:

1. **Smoke test** — run `~/.local/bin/net-sentry` in foreground; verify it does NOT immediately alert (seed-without-alert behavior).
2. **Down path** — turn Wi-Fi off; within 2–3 seconds expect (a) spoken voice, (b) modal popup, (c) notification banner — all roughly simultaneous.
3. **Recovery path** — turn Wi-Fi back on; expect ONLY a notification banner ("Internet is back"). No voice, no modal.
4. **Debounce** — toggle Wi-Fi off and back on within ~1 second; expect NO alert at all.
5. **Concurrency check** — during step 2, confirm the modal does not delay the spoken voice (they should overlap, not serialize).
6. **launchd respawn** — `pkill net-sentry`; confirm process is back within ~5 seconds via `pgrep -f net-sentry`.
7. **Config tweak** — set `[notifiers.modal] enabled = false`, restart daemon (`launchctl kickstart -k gui/$(id -u)/link.smirnov.net-sentry`), repeat step 2; expect voice + banner but no modal.

## Open questions / future work

- **Hot-reload of config** (out of scope for v1) — would require `DispatchSourceFileSystemObject` watching the config file. Easy add later.
- **Captive-portal detection** (out of scope for v1) — NWPathMonitor reports `.satisfied` on captive-portal Wi-Fi, so the daemon won't alert when stuck behind a hotel/airport sign-in. A future v2 could add a one-shot `captive.apple.com` probe on every `.satisfied` transition to confirm true reachability.
- **Custom notifier types** (webhook, Slack, IFTTT) — could be added by extending the TOML schema with `[notifiers.webhook]` and one new shell-out template. Architecturally already supported by the Alerter design.
