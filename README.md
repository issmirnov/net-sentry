# net-sentry

Tiny macOS daemon that loudly alerts you when the internet drops — designed for the "I was voice-dictating and didn't notice Wi-Fi died" failure mode.

## Install

    ./install.sh

## Configure

Edit `~/Library/Application Support/net-sentry/config.toml` to change voice, text, channels, or debounce.

## Logs

Tail `~/Library/Logs/net-sentry.{out,err}.log` or open `Console.app`.

## Uninstall

    ./uninstall.sh
