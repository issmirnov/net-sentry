#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Building (release)..."
swift build -c release

echo "==> Installing binary to ~/.local/bin/..."
install -d "$HOME/.local/bin"
install ".build/release/net-sentry" "$HOME/.local/bin/net-sentry"

echo "==> Seeding config (only if absent)..."
CONFIG_DIR="$HOME/Library/Application Support/net-sentry"
install -d "$CONFIG_DIR"
if [ -f "$CONFIG_DIR/config.toml" ]; then
    echo "    config.toml already exists — preserving your edits"
else
    cp config.example.toml "$CONFIG_DIR/config.toml"
    echo "    copied config.example.toml -> $CONFIG_DIR/config.toml"
fi

echo "==> Installing LaunchAgent..."
install -d "$HOME/Library/Logs"
install -d "$HOME/Library/LaunchAgents"
sed "s|__HOME__|$HOME|g" link.smirnov.net-sentry.plist \
    > "$HOME/Library/LaunchAgents/link.smirnov.net-sentry.plist"

echo "==> Bootstrapping daemon..."
launchctl bootout  "gui/$(id -u)/link.smirnov.net-sentry" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/link.smirnov.net-sentry.plist"

sleep 1
if pgrep -fq "$HOME/.local/bin/net-sentry"; then
    echo "==> ✓ net-sentry is running."
else
    echo "==> ✗ daemon failed to start; check ~/Library/Logs/net-sentry.err.log"
    exit 1
fi
