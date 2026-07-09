# Listener installer package — design

**Goal:** a manager installs the Mac sync listener by downloading one `.pkg`
from GitHub Releases and double-clicking it. The Installer app's own admin
prompt covers everything that needs root (firewall Allow, system LaunchAgent).
No git clone, no Xcode, no Terminal.

## Why a signed productbuild pkg

- A Homebrew tap forces managers through developer tooling — rejected.
- A menu-bar `.app` is a real product surface (UI, updates) — out of scope.
- A `.pkg` is the native "double-click, admin prompt, done" artifact, and the
  postinstall script runs as root, which is exactly where the firewall
  `socketfilterfw` calls and LaunchAgent bootstrap belong.

## Package contents and layout

| Artifact | Destination | Notes |
|---|---|---|
| `luxicon-mcp` binary | `/usr/local/bin/luxicon-mcp` | root-owned 755; also on PATH for `claude mcp add luxicon` |
| LaunchAgent plist | `/Library/LaunchAgents/edu.davidson.luxicon.listener.plist` | runs for every user at login |
| Uninstaller | `/usr/local/bin/luxicon-listener-uninstall` | boots out agents, removes binary + plist + firewall rule; leaves `~/Luxicon` data |

The LaunchAgent execs via `/bin/sh -c 'exec /usr/local/bin/luxicon-mcp listen
>> "$HOME/Library/Logs/luxicon-listener.log" 2>&1'` — launchd doesn't expand
`~`, the shell does, so each user gets their own log. Per-user library and
pairing token stay at `~/Luxicon` exactly as today.

## Postinstall script (runs as root inside Installer.app)

1. `socketfilterfw --add` + `--unblockapp` on `/usr/local/bin/luxicon-mcp`.
2. Migration: if the console user has the old per-user install
   (`~/bin/luxicon-mcp` + `~/Library/LaunchAgents/<label>.plist` from
   `scripts/install-listener.sh`), boot it out and delete the plist — the
   labels collide. The `~/bin` binary is left in place (harmless).
3. Bootstrap the system agent for the console user immediately
   (`launchctl bootstrap gui/<uid-of-/dev/console>`), so the listener is up
   without logout. Other users get it at next login via RunAtLoad.

Idempotent: re-running the installer over itself must succeed (kickstart
instead of bootstrap when already loaded).

## Build pipeline

`scripts/build-installer.sh`:

1. `swift build -c release --product luxicon-mcp` — arm64-only (MLX links
   transitively and is Apple-Silicon-only; matches the product's hardware
   floor).
2. Sign the binary: Developer ID Application, `--options runtime --timestamp`
   (hardened runtime required by notarization).
3. Stage payload + scripts, `pkgbuild` (identifier
   `edu.davidson.luxicon.listener.pkg`, version from git describe/CHANGELOG),
   `productbuild` with a distribution XML (title, arm64 host requirement).
4. If `LUXICON_INSTALLER_IDENTITY` is set (a "Developer ID Installer" cert):
   sign the product archive; then `xcrun notarytool submit --keychain-profile
   luxicon --wait` and `xcrun stapler staple`. Without it: emit an unsigned
   pkg and a loud warning (fine for local right-click→Open testing, not for
   distribution).
5. Output `dist/LuxiconListener-<version>.pkg`.

`.github/workflows/release-listener.yml` (modeled on Oncillascope's release
workflow): on `listener-v*` tag push — build, sign, package, notarize with the
`AC_*` repo secrets (already set), staple, attach to a GitHub Release. Its
signing steps additionally need `DEVELOPER_ID_P12`/`DEVELOPER_ID_P12_PASSWORD`
and an Installer-cert P12 — keychain export is GUI-gated, so CI signing is a
follow-up; local releases are the primary path.

## Credentials status (2026-07-09)

- Notarization: **working** — keychain profile `luxicon` validated against
  Apple; `AC_APPLE_ID`/`AC_TEAM_ID`/`AC_APP_PASSWORD` set on the repo.
- Developer ID Application: in the login keychain (signs the binary).
- Developer ID Installer: **missing — the one manual prerequisite.** Only the
  Apple account holder can mint it (Xcode → Settings → Accounts → Manage
  Certificates → + → Developer ID Installer). Until then the pkg builds
  unsigned and cannot be notarized (Apple rejects unsigned installers).

## Docs

`docs/sync.md` gains a manager-facing "Install on your Mac" section at the
top of the pairing flow: download the pkg from Releases, double-click, enter
the admin password once, read the token with `cat ~/Luxicon/.sync-token`.
The script-based flow stays documented for developers.

## Testing

- `bash -n` + shellcheck on all scripts; `pkgutil --expand` structural checks
  (payload paths, plist lint, scripts executable).
- Local end-to-end install (`sudo installer -pkg`) and the double-click
  admin-prompt UX need the user — the GUI prompt can't be driven from here.
- Idempotency: install over an existing install; migration: install over the
  old `~/bin` layout.
