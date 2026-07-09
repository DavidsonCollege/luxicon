#!/bin/bash
# Build, sign, install, firewall-allow, and restart the Luxicon sync listener.
#
# Why signing: the macOS application firewall remembers "Allow" by the
# binary's code-signing identity. Ad-hoc builds get a fresh identity every
# rebuild, so the firewall silently re-blocks them (phone pushes then fail
# with "The listener did not confirm the transfer"). A stable Developer ID
# signature makes one Allow permanent.
set -euo pipefail

# Signing identity: LUXICON_SIGN_IDENTITY if set, else the first codesigning
# identity in the keychain (Developer ID or a free Apple Development cert —
# any identity works as long as it's the same one every rebuild). Empty means
# ad-hoc fallback below.
IDENTITY="${LUXICON_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' 'NR==1 {print $2}')}"
BIN="$HOME/bin/luxicon-mcp"
LABEL="edu.davidson.luxicon.listener"
FW=/usr/libexec/ApplicationFirewall/socketfilterfw

cd "$(dirname "$0")/.."

echo "==> Building"
swift build -c release --product luxicon-mcp

if [ -n "$IDENTITY" ]; then
    echo "==> Signing as: $IDENTITY"
    codesign --force --sign "$IDENTITY" .build/release/luxicon-mcp
else
    echo "==> WARNING: no codesigning identity found; signing ad-hoc."
    echo "    The firewall Allow will NOT survive rebuilds — macOS will silently"
    echo "    re-block the listener after each install. Create a (free) Apple"
    echo "    Development certificate in Xcode, or set LUXICON_SIGN_IDENTITY."
    codesign --force --sign - .build/release/luxicon-mcp
fi

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
