# Permanent firewall fix for the sync listener — design

**Date:** 2026-07-09
**Status:** Approved

## Problem

The macOS application firewall blocked incoming connections to
`~/bin/luxicon-mcp`, so phone pushes timed out with "The listener did not
confirm the transfer" (Bonjour discovery still worked — mDNS is answered by
the system — so the phone found the Mac and then hung connecting).

A one-time `socketfilterfw --unblockapp` fixes today, but not permanently:
the installed binary is ad-hoc, linker-signed, so every rebuild produces a
new code identity and the firewall's decision cannot follow it. The manual
install flow in docs/sync.md (`install .build/release/luxicon-mcp ~/bin/`)
reproduces the problem on every update.

Secondary finding from the same diagnosis: `luxicon-listener.log` is always
empty because `print` output is block-buffered when stdout is a file — the
listener's banner and "Received …" lines never flush while it runs, making
server-side diagnosis impossible.

## Fix

### 1. Stable code signature

The firewall persists trust by the signature's designated requirement
(identifier + signing certificate), not the file hash. Signing every build
with the Mac's existing stable identity —
`Developer ID Application: The Trustees of Davidson College (4Z539UE4TT)` —
makes one firewall "Allow" hold across all future rebuilds.

Plain `codesign --force --sign` (no `--timestamp`, which needs network and
is only required for notarization; no hardened runtime, which risks breaking
MLX/Metal and buys nothing for firewall trust).

### 2. `scripts/install-listener.sh`

One idempotent command that encodes the whole flow:

1. `swift build -c release --product luxicon-mcp`
2. `codesign --force --sign "<Developer ID>"` the built binary
3. `install` it to `~/bin/luxicon-mcp` (signature survives the copy)
4. `sudo socketfilterfw --add` + `--unblockapp` on `~/bin/luxicon-mcp`
   (idempotent; the only sudo step; with the stable signature this is
   effectively one-time, but re-running is harmless)
5. `launchctl kickstart -k gui/$UID/edu.davidson.luxicon.listener` to
   restart the LaunchAgent on the new binary; prints a pointer to
   docs/sync.md if the agent isn't loaded

`set -euo pipefail`; paths and the identity as variables at the top.

### 3. Line-buffered listener log

`setvbuf(stdout, nil, _IOLBF, 0)` at the top of `SyncListener.run` so the
banner and per-push lines appear in `luxicon-listener.log` as they happen,
including under launchd.

### 4. Docs

Update the LaunchAgent section of docs/sync.md: replace the manual
build/install commands with the script, explain the firewall/signing
rationale in a sentence or two, and change the "after pulling new code"
note to "re-run `scripts/install-listener.sh`".

## Out of scope

- Notarization/distribution of luxicon-mcp to other Macs.
- Signing the CLI (`luxicon-cli`) — it makes only outgoing connections.

## Verification

- `codesign -dv ~/bin/luxicon-mcp` shows the Developer ID (not `adhoc`).
- `socketfilterfw --listapps` shows luxicon-mcp as Allow.
- A loopback CLI push lands in `~/Luxicon` AND its "Received …" line appears
  in `luxicon-listener.log` immediately (proves the buffering fix).
- Phone push (JD): Retry Push flips the failed session to synced.
- Rebuild + re-run the script, push again with no firewall prompt — proves
  permanence.
