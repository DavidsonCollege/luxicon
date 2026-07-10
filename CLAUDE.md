# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Swift package (LuxiconKit + luxicon-cli + luxicon-mcp)
swift build                          # debug; -c release for the real thing
swift test                           # swift-testing; offline, no model downloads
swift test --filter SyncTests        # single suite (suite names, e.g. VocabularyTests)
bash scripts/build_mlx_metallib.sh debug   # required once before running the CLI (MLX Metal shaders)

# iOS app (App/ — xcodegen project; the .xcodeproj is generated, never edit it)
cd App && xcodegen generate          # REQUIRED after adding/removing source files (project.yml is the source of truth)
xcodebuild -project Luxicon.xcodeproj -scheme Luxicon \
  -destination 'generic/platform=iOS' -configuration Release -allowProvisioningUpdates build
# Install on a device with `xcrun devicectl device install app --device <id> \
#   ~/Library/Developer/Xcode/DerivedData/Luxicon-*/Build/Products/Release-iphoneos/Luxicon.app`
# Use Release for device installs — Debug builds depend on the stub-executor debug dylib.

# Mac sync listener — install ONLY via the script (builds, codesigns, installs to
# ~/bin, allows through the macOS firewall, restarts the LaunchAgent).
# Hand-copying the binary re-blocks it: the firewall keys "Allow" to the code
# signature, and ad-hoc builds get a new one every rebuild (docs/sync.md).
scripts/install-listener.sh
```

Building the app requires Xcode 26+ (iOS 26 SDK symbols, runtime-gated); deployment target is iOS 18. Diarization uses MLX/Metal and does not run in the iOS Simulator — use a physical device, or the CLI on a Mac.

## Releasing (TestFlight, App Store, listener installer)

**Read [docs/releasing.md](docs/releasing.md) before any release work.** It maps every flow to the exact credentials it uses and where they live (Xcode account session for App Store uploads — there is no API key on this machine and `altool` is dead; Developer ID identities in the login keychain; notarytool keychain profile `luxicon`; GitHub Actions secrets for CI listener releases). Never write credential values into this public repo.

## Architecture

Three layers, split by what must stay platform-neutral:

- **`Sources/LuxiconKit/`** — core library, no UI or app dependencies. The pipeline (`MeetingPipeline`: diarize → per-turn ASR → speaker matching), transcript/export models, vocabulary correction, and the LAN sync protocol (`LuxiconSync` + `SyncPusher`: TLS-PSK derived from a pairing token, Bonjour `_luxicon._tcp`, port 51234, length-prefixed frames — deliberately no TLS half-close, which deadlocks the ack).
- **`Sources/LuxiconCLI/` and `Sources/LuxiconMCP/`** — macOS executables over LuxiconKit. `luxicon-mcp` is both the MCP server (stdio, re-scans the library folder each call) and, via `listen`, the sync receiver that writes phone pushes into `~/Luxicon`. `luxicon-cli push` exercises the same sync path the app uses — the fastest way to test the listener without a phone (`--host 127.0.0.1` bypasses both Bonjour and the firewall).
- **`App/`** — SwiftUI iOS app. All state lives in `Store` (`@Observable @MainActor`, `App/Sources/Store.swift`), persisted as JSON in the Documents container. Feature logic is written as `Store` extensions in sibling files (`MacSyncService.swift`, `VocabularySync.swift`, `SessionProcessing.swift`, …) rather than separate service objects.

Sync topology is one-directional by design: the phone is always the client and pushes finished sessions to the Mac, because iOS suspends backgrounded apps. Every push outcome is recorded on the `SessionRecord` (`lastPushDate`/`lastPushError`) and surfaced in the UI; failed pushes retry on foreground.

Constraints that aren't obvious from any single file:

- **Persistence back-compat:** `Store.Persisted` and `SessionRecord` decode existing `store.json` files from released builds. New fields must be optionals (or have defaults applied in `load()`); never rename or repurpose existing keys. Secrets (pairing token, sync auth headers) live in the Keychain, not `store.json`.
- **Tests cover LuxiconKit only.** There is no app-target test bundle; app changes are verified by building and checking on a device. Tests must stay offline (no model downloads).
- **Wire-protocol changes** (`LuxiconSync`, `SyncPusher`, `SyncListener`) span the app and the installed Mac binary — after changing them, reinstall both sides or pushes fail in confusing ways.
- The privacy posture in README.md is load-bearing App Store copy: everything is on-device; the only network features are opt-in Mac sync (LAN-only) and https-only vocabulary/people URL sync. Don't add network calls outside those paths. (User-initiated link-outs that open in Safari — the giving screen's davidson.edu/giving and GitHub links — are fine and deliberate: App Store rule 3.2.1 requires donations to happen outside the app.)
