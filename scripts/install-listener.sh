#!/bin/bash
# Build, sign, install, firewall-allow, and restart the Luxicon sync listener.
#
# Why signing: the macOS application firewall remembers "Allow" by the
# binary's code-signing identity. Ad-hoc builds get a fresh identity every
# rebuild, so the firewall silently re-blocks them (phone pushes then fail
# with "The listener did not confirm the transfer"). A stable Developer ID
# signature makes one Allow permanent.
set -euo pipefail

# Signing identity: LUXICON_SIGN_IDENTITY if set, else prefer a Developer ID
# certificate, else the first codesigning identity in the keychain (a free
# Apple Development cert works — any identity is fine as long as it's the
# same one every rebuild). Empty means ad-hoc fallback below.
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if [ -n "${LUXICON_SIGN_IDENTITY:-}" ]; then
    IDENTITY="$LUXICON_SIGN_IDENTITY"
else
    IDENTITY="$(printf '%s\n' "$IDENTITIES" | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
    [ -n "$IDENTITY" ] || IDENTITY="$(printf '%s\n' "$IDENTITIES" | awk -F'"' 'NR==1 {print $2}')"
    if [ "$(printf '%s\n' "$IDENTITIES" | grep -c '"')" -gt 1 ]; then
        echo "==> Multiple signing identities found; using: $IDENTITY"
        echo "    (override with LUXICON_SIGN_IDENTITY — keep it the SAME every rebuild,"
        echo "     the firewall Allow is keyed to it)"
    fi
fi
BIN="$HOME/bin/luxicon-mcp"
LABEL="edu.davidson.luxicon.listener"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
FW=/usr/libexec/ApplicationFirewall/socketfilterfw

cd "$(dirname "$0")/.."

# Take the sudo prompt before mutating anything: a dismissed password after
# the binary is replaced would leave a new build with no firewall Allow —
# the exact silent-block failure this script exists to prevent.
echo "==> This script needs sudo for the firewall Allow (two socketfilterfw calls)."
sudo -v

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
if [ ! -f "$PLIST" ]; then
    echo "==> Creating $PLIST"
    cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$BIN</string>
		<string>listen</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardOutPath</key>
	<string>$HOME/Library/Logs/luxicon-listener.log</string>
	<key>StandardErrorPath</key>
	<string>$HOME/Library/Logs/luxicon-listener.log</string>
</dict>
</plist>
PLIST_EOF
fi
if launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null; then
    echo "Done. Listener restarted on the new binary."
else
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "Done. Listener loaded (starts at every login from now on)."
fi
echo "Pairing token: $HOME/Luxicon/.sync-token (created on first listen)"
