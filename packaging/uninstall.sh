#!/bin/bash
# Remove the Luxicon sync listener installed by LuxiconListener.pkg.
# Your ~/Luxicon library (transcripts + pairing token) is left untouched —
# delete it yourself if you want a clean slate.
set -u

LABEL=edu.davidson.luxicon.listener

if [ "$(id -u)" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

uid=$(stat -f %u /dev/console 2>/dev/null || echo 0)
[ "$uid" -gt 0 ] && launchctl bootout "gui/$uid/$LABEL" >/dev/null 2>&1

/usr/libexec/ApplicationFirewall/socketfilterfw --remove /usr/local/bin/luxicon-mcp >/dev/null 2>&1
rm -f "/Library/LaunchAgents/$LABEL.plist" /usr/local/bin/luxicon-mcp
rm -rf /usr/local/share/luxicon
pkgutil --forget edu.davidson.luxicon.listener.pkg >/dev/null 2>&1
rm -f /usr/local/bin/luxicon-listener-uninstall

echo "Luxicon listener removed. Your ~/Luxicon library was left untouched."
