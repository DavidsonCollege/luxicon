#!/bin/bash
# Build, sign, install, firewall-allow, and restart the Luxicon sync listener.
#
# Why signing: the macOS application firewall remembers "Allow" by the
# binary's code-signing identity. Ad-hoc builds get a fresh identity every
# rebuild, so the firewall silently re-blocks them (phone pushes then fail
# with "The listener did not confirm the transfer"). A stable Developer ID
# signature makes one Allow permanent.
set -euo pipefail

IDENTITY="Developer ID Application: The Trustees of Davidson College (4Z539UE4TT)"
BIN="$HOME/bin/luxicon-mcp"
LABEL="edu.davidson.luxicon.listener"
FW=/usr/libexec/ApplicationFirewall/socketfilterfw

cd "$(dirname "$0")/.."

echo "==> Building"
swift build -c release --product luxicon-mcp

echo "==> Signing"
codesign --force --sign "$IDENTITY" .build/release/luxicon-mcp

echo "==> Installing to $BIN"
mkdir -p "$HOME/bin"
install .build/release/luxicon-mcp "$BIN"

echo "==> Allowing through the application firewall (sudo)"
# Idempotent: --add is a no-op when already listed; --unblockapp flips any
# Block rule to Allow.
sudo "$FW" --add "$BIN"
sudo "$FW" --unblockapp "$BIN"

echo "==> Restarting LaunchAgent"
if launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null; then
    echo "Done. Listener restarted on the new binary."
else
    echo "LaunchAgent $LABEL is not loaded — set it up per docs/sync.md."
fi
