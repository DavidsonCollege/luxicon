# Mac sync — pairing and troubleshooting

Luxicon can push finished transcripts (and summaries) from the iPhone to a
Mac over your local network, so the MCP server can serve them to Claude
without AirDrop round-trips.

## How it works

- The Mac runs `luxicon-mcp listen`, which advertises `_luxicon._tcp` via
  Bonjour on port 51234 and prints a **pairing token** (also stored beside
  the library at `.sync-token`, chmod 600).
- The phone connects with TLS-PSK: both sides derive the key from the
  pairing token (SHA-256), so nothing on the wire is readable — and nothing
  can be pushed — without the token. Traffic never leaves your LAN.
- Pushes are one file per connection; re-pushing a session after its summary
  lands simply overwrites the same file (idempotent).

## Install on your Mac (managers — no Terminal required to install)

Download `LuxiconListener-<version>.pkg` from the repo's
[Releases page](https://github.com/DavidsonCollege/luxicon/releases),
double-click it, and enter your Mac password when asked — that one prompt
covers everything (the network permission and the login item). The listener
starts immediately and at every login. Apple Silicon Macs only.

The installer puts the binary at `/usr/local/bin/luxicon-mcp` and the login
item at `/Library/LaunchAgents` (all users); it also migrates and replaces a
developer-style `~/bin` install if one exists. To remove it later, run
`luxicon-listener-uninstall` in Terminal. Developers building from a checkout
can use `scripts/install-listener.sh` instead (next section), or build the
pkg themselves with `scripts/build-installer.sh`.

## Pairing

1. On the Mac: install the listener (pkg above, or the script below), then
   read the token: open Terminal and run `cat ~/Luxicon/.sync-token`.
2. On the iPhone: **My Voice → Mac sync**, enter the token.
3. Optional: toggle **Push automatically after each 1-on-1**, or use
   **Push All to Mac** from a person's share menu.

## Run the listener automatically at login

A LaunchAgent keeps the listener alive so you never have to remember a
terminal window. Install the binary with the script — it builds, signs,
installs to `~/bin` (pointing launchd into `.build/` breaks the next time
`swift package clean` runs), allows it through the macOS firewall, and
restarts the agent:

```bash
scripts/install-listener.sh
```

Signing matters: the firewall remembers "Allow" by code-signing identity,
and unsigned builds get a new identity each rebuild — the firewall then
silently blocks the listener and phone pushes fail with "The listener did
not confirm the transfer". If no signing certificate is in your keychain,
the script signs ad-hoc and warns; that Allow holds only for builds
installed through the script — a rebuild done outside it gets re-blocked.
The script also creates and loads the LaunchAgent below if it isn't set up
yet, so on a fresh Mac it is the only command you need.

Save this as `~/Library/LaunchAgents/edu.davidson.luxicon.listener.plist`,
replacing `YOURUSER` with your username:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>edu.davidson.luxicon.listener</string>
	<key>ProgramArguments</key>
	<array>
		<string>/Users/YOURUSER/bin/luxicon-mcp</string>
		<string>listen</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardOutPath</key>
	<string>/Users/YOURUSER/Library/Logs/luxicon-listener.log</string>
	<key>StandardErrorPath</key>
	<string>/Users/YOURUSER/Library/Logs/luxicon-listener.log</string>
</dict>
</plist>
```

Then load it (starts at login from now on, restarts if it dies):

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/edu.davidson.luxicon.listener.plist
```

Verify with `lsof -nP -i :51234` (should show `luxicon-m … LISTEN`), or
read the startup banner in `~/Library/Logs/luxicon-listener.log`. The
pairing token is also in `~/Luxicon/.sync-token`.

Housekeeping:

- After pulling new code, re-run `scripts/install-listener.sh` — it
  rebuilds, re-signs, and restarts the agent in one go.
- To stop it: `launchctl bootout gui/$(id -u)/edu.davidson.luxicon.listener`.
- The listener prints the pairing token at startup, so the log file is as
  sensitive as `.sync-token` — both are readable only by your account.

## When a push fails

Each session shows its sync state (small laptop mark on the row; open the
session for the **Mac Sync** section with the exact error and a retry
button). What each message means:

- **"No Mac listener found on this network"** — Bonjour discovery failed:
  the listener isn't running, mDNS is blocked (enterprise Wi-Fi often does
  this), or the devices are on different networks / an isolated guest SSID.
  The listener prints the Mac's IP addresses at startup — enter one under
  **Mac address** on the phone and Luxicon connects directly to port 51234.
- **"Local network access was blocked"** — iOS **Local Network** permission
  was declined on the first push; re-enable it in Settings → Privacy &
  Security → Local Network → Luxicon.
- **"Connection failed … (check the pairing token)"** — the Mac answered but
  the TLS handshake or connection failed. Usually a wrong or stale token:
  re-copy it from `~/Luxicon/.sync-token` on the Mac.
- **"The listener did not confirm the transfer"** — the push timed out
  mid-flight. Prime suspect: the macOS application firewall blocking the
  listener (Bonjour still works because the *system* answers mDNS, so the
  phone finds the Mac and then hangs connecting). Re-run
  `scripts/install-listener.sh`, or check with
  `/usr/libexec/ApplicationFirewall/socketfilterfw --listapps | grep -A1 luxicon`
  — it must say "Allow incoming connections". Also possible: the Mac is
  asleep, or the listener is wedged
  (`tail ~/Library/Logs/luxicon-listener.log`).

Failed pushes retry automatically the next time the app foregrounds (when
automatic push is on), or manually via **Retry Push** on the session.

## Security notes

- The pairing token is the only credential. On the phone it is stored in
  the Keychain; on the Mac, in `.sync-token` next to the library. Delete
  that file to force a new token (re-pair the phone afterwards).
- Sessions use `TLS_PSK_WITH_AES_128_GCM_SHA256`. There is no forward
  secrecy: treat the token like a password and rotate it if a device is
  compromised.
- The listener accepts frames up to 64 MiB and only writes sanitized
  `*.json` filenames inside the library directory.
