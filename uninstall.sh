#!/usr/bin/env bash
set -euo pipefail

echo "==> Bootout LaunchAgent (if loaded)..."
launchctl bootout "gui/$(id -u)/link.smirnov.net-sentry" 2>/dev/null || true

echo "==> Removing LaunchAgent plist..."
rm -f "$HOME/Library/LaunchAgents/link.smirnov.net-sentry.plist"

echo "==> Removing binary..."
rm -f "$HOME/.local/bin/net-sentry"

echo "==> Preserved (NOT removed): $HOME/Library/Application Support/net-sentry/config.toml"
echo "==> Preserved (NOT removed): $HOME/Library/Logs/net-sentry.{out,err}.log"

echo "==> ✓ uninstalled."
