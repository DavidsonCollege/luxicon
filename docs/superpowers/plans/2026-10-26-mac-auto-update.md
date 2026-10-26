# Luxicon for Mac Auto-Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Luxicon for Mac checks GitHub for new versions with Sparkle 2.x. A pushed `mac-v<marketing>-<build>` tag, once JD approves it in GitHub Actions, builds, notarizes, EdDSA-signs and publishes the release and its appcast.

**Architecture:**
- **Testable logic:** the timing rule ("hold the update alert and the relaunch while busy") is a small pure type in LuxiconKit, where tests run.
- **App side:** a Mac-only `MacUpdater` wraps Sparkle's standard updater controller, feeds that type the app's busy state, and adds the menu item.
- **Release pipeline:** `scripts/build-mac-app.sh` stays the single build path, now able to run in CI. A new workflow runs it on tag push in a `release` environment JD must approve, then publishes the DMG and regenerates `appcast.xml` on `gh-pages`.

**Tech Stack:**
- Swift 6 and SwiftUI on macOS 15+ (arm64), via xcodegen
- Sparkle 2.x via SwiftPM, on the LuxiconMac target only
- GitHub Actions on `macos-26`
- Sparkle's `generate_keys`, `generate_appcast` and `sign_update`
- swift-testing

**Spec:** `docs/superpowers/specs/2026-10-26-mac-auto-update-design.md`

## Global Constraints

**Platform and dependencies**
- Sparkle is linked into **LuxiconMac only**: not the iOS target, the widget, LuxiconKit, luxicon-cli or luxicon-mcp. The iOS Release binary must contain no Sparkle symbols.
- Pin Sparkle exactly: `exactVersion` in `App/project.yml`, and the same version plus the tools tarball's SHA-256 in the workflow. Use the newest 2.x release available at build time, and record it in the Task 2 commit message.

**Info.plist keys** (LuxiconMac, via `App/project.yml` `info.properties`)
- `SUFeedURL` = `https://davidsoncollege.github.io/luxicon/appcast.xml`
- `SUPublicEDKey` = the public key from Task 2 Step 1
- `SUEnableSystemProfiling` = `false`
- `SUEnableAutomaticChecks` must NOT be present, so Sparkle asks the person first.

**Privacy**
- No update network request happens before the person opts in, except one they start with Check for Updates….
- Only `davidsoncollege.github.io` and the GitHub Release download are contacted.

**Signing**
- The app keeps exactly one entitlement, `com.apple.security.device.audio-input` = true; `scripts/build-mac-app.sh` keeps asserting that.
- Sparkle's nested helpers must carry the hardened runtime and the Developer ID Application authority (team `4Z539UE4TT`).

**Secrets**
- No private key or credential value ever goes in the repo, a doc, a commit message or a log line.
- `SPARKLE_ED_PRIVATE_KEY` is an **environment** secret on `release`, not a repo secret.
- The listener workflow's repo-level secrets stay where they are.
- Luxicon's Sparkle key lives under keychain account `edu.davidson.luxicon.mac`, never the default account, which may hold Oncillascope's key.

**Releases**
- Tag format: `mac-v<MARKETING_VERSION>-<CURRENT_PROJECT_VERSION>`, e.g. `mac-v1.0-19`. The workflow refuses a tag that doesn't match `App/project.yml`.
- Claude never pushes a `mac-v*` tag, enables Pages, creates environments, pushes `gh-pages`, or sets secrets without JD's go-ahead in the conversation.

**Process**
- `App/project.yml` is the source of truth; run `cd App && xcodegen generate` after changing it. Never edit the `.xcodeproj`.
- DEBUG builds must not touch the real app's Sparkle state. The updater is off in DEBUG unless `-enableUpdater` is passed. Every automated run that enables it uses a build whose bundle id is overridden to `edu.davidson.luxicon.mac.updatetest`, and that defaults domain is deleted afterward.
- Never automate against the real `~/Luxicon`, `~/Library/Application Support/Luxicon` or `/Applications/Luxicon.app`. Use `-storePath`/`-libraryPath` scratch dirs.

## Review Focus

1. **Update found mid-recording:** no alert appears over the recording window. The alert appears once it closes; a relaunch waits for the recording and for transcription to finish. (Task 1 tests, Task 6 Step 3.)
2. **Offline, or GitHub unreachable:** a background check fails silently; a manual check shows Sparkle's error and the app keeps working. (Task 6 Step 4.)
3. **Tampered or wrongly signed update:** Sparkle refuses to install it. (Task 6 Step 5.)
4. **Tag that doesn't match the project version:** the workflow stops before building. (Task 3 Step 1 cases.)
5. **Feed regeneration drops older releases or points at the wrong asset URL:** publish aborts. Every enclosure URL is under `https://github.com/DavidsonCollege/luxicon/releases/download/<tag>/`. (Task 4 guard, Task 7 dry-run check.)

---

### Task 1: `UpdateDeferral` in LuxiconKit

**Files:**
- Create: `Sources/LuxiconKit/UpdateDeferral.swift`
- Test: `Tests/LuxiconKitTests/UpdateDeferralTests.swift`

**Interfaces:**
- Produces:
  ```swift
  /// Holds update UI and relaunches while the app is busy (recording window
  /// open, recording, or a session processing); runs them once it's idle.
  @MainActor public final class UpdateDeferral {
      public init()
      public private(set) var isBusy: Bool          // starts false
      /// Updates busy state; on a busy → idle transition runs every held
      /// action once, in the order held, then forgets them.
      public func setBusy(_ busy: Bool)
      /// Not busy: returns false and doesn't keep `action` (caller proceeds).
      /// Busy: keeps `action` and returns true (caller must not proceed).
      public func holdIfBusy(_ action: @escaping @MainActor () -> Void) -> Bool
  }
  ```

- [ ] **Step 1: Write the failing tests** (suite `UpdateDeferralTests`):
  - `notBusyDoesNotHold`: `holdIfBusy` returns `false` and the action never runs, including after `setBusy(true)` and then `setBusy(false)`.
  - `busyHoldsUntilIdle`: after `setBusy(true)`, `holdIfBusy` returns `true` and the action hasn't run. After `setBusy(false)` it has run exactly once.
  - `runsInOrderOnce`: two held actions append `"a"` and `"b"` to a log. After `setBusy(false)` the log is `["a","b"]`. Another `setBusy(true)` / `setBusy(false)` cycle leaves it `["a","b"]`.
  - `repeatedBusyDoesNotRun`: `setBusy(true)` twice leaves a held action unrun.
  - `idleToIdleDoesNotRun`: `setBusy(false)` while already idle runs nothing.
- [ ] **Step 2:** Run `swift test --filter UpdateDeferralTests`. Expected: FAIL (`UpdateDeferral` is not defined).
- [ ] **Step 3:** Implement `UpdateDeferral` in `Sources/LuxiconKit/UpdateDeferral.swift`. An action held during an action's own run must not run in the same pass: copy the list and clear it before running.
- [ ] **Step 4:** Run `swift test`. Expected: all pass (190 existing tests plus the new ones).
- [ ] **Step 5:** Commit: `Kit: UpdateDeferral holds update UI and relaunches while busy`.

### Task 2: Sparkle in the Mac app

**Files:**
- Modify: `App/project.yml` (add the Sparkle package, the LuxiconMac dependency and the Info keys)
- Create: `App/MacSources/MacUpdater.swift`
- Modify: `App/MacSources/LuxiconMacApp.swift` (own the updater, wire busy state)
- Modify: `App/MacSources/MacCommands.swift` (menu item)
- Modify: `App/MacSources/MacRootView.swift` (`MacNavigation.recordingPerson` reports changes)
- Modify: `App/Sources/SessionProcessing.swift` (`refreshKeepAwake` reports changes on macOS)
- Modify: `App/MacSources/DebugLaunchOptions.swift` (register `-enableUpdater` and `-updateFeedURL`)

**Interfaces:**
- Consumes: `UpdateDeferral` (Task 1).
- Produces:
  ```swift
  @MainActor @Observable final class MacUpdater: NSObject {
      init()                       // DEBUG: Sparkle not started unless -enableUpdater
      var canCheckForUpdates: Bool { get }
      func checkForUpdates()       // user-initiated; never deferred
      func setBusy(_ busy: Bool)   // forwards to UpdateDeferral
  }
  ```
  Also `ProcessingState.onBusyChange: (@MainActor () -> Void)?` (`@ObservationIgnored`, macOS only) and `MacNavigation.onRecordingPersonChange: (@MainActor () -> Void)?`.

- [ ] **Step 1: Generate Luxicon's key pair.**
  1. Download the pinned Sparkle tools tarball into scratch and check its SHA-256.
  2. Run `generate_keys --account edu.davidson.luxicon.mac -p`. If it prints a key, the key already exists: reuse it.
  3. Otherwise run `generate_keys --account edu.davidson.luxicon.mac` and note the printed **public** key.

  Never run `-x` here; exporting the private key is Task 7's job. The public key goes in `SUPublicEDKey`.
- [ ] **Step 2:** In `App/project.yml`, add the Sparkle package under `packages:` with `url: https://github.com/sparkle-project/Sparkle` and `exactVersion`. Add `- package: Sparkle` to LuxiconMac's dependencies only, and the three Info keys from Global Constraints. Then run `cd App && xcodegen generate`.
- [ ] **Step 3:** Write `MacUpdater` in `App/MacSources/MacUpdater.swift`:
  - **Controller:** wrap `SPUStandardUpdaterController(startingUpdater:updaterDelegate:userDriverDelegate:)`, with `self` as both delegates.
  - **Delegates:**
    - **Relaunch:** `updater(_:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)` returns `deferral.holdIfBusy(block)`.
    - **Scheduled alert:** set `supportsGentleScheduledUpdateReminders` to `true`. In `standardUserDriverShouldHandleShowingScheduledUpdate(_:andInImmediateFocus:)`, return `false` while busy, and hold an action that calls `updater.checkForUpdates()` once idle. Return `true` otherwise.
    - **Manual checks:** never deferred.
  - **`canCheckForUpdates`:** mirror the updater's KVO property.
  - **DEBUG:**
    - Without `-enableUpdater`, the controller is created with `startingUpdater: false` and `canCheckForUpdates` stays false.
    - `-updateFeedURL <url>` overrides the feed through `feedURLString(for:)`.
    - Both flags are DEBUG-only and registered in `DebugLaunchOptions`' value table.
- [ ] **Step 4: Wire it up.**
  - **Busy rule:** in `MacAppDelegate`, own `let updater = MacUpdater()` and compute busy as `navigation.recordingPerson != nil || store.processing.recordingActive || !store.processing.bySession.isEmpty`.
  - **Hooks:** call `updater.setBusy(busy)` from `ProcessingState.onBusyChange`, which runs at the end of `refreshKeepAwake()` on macOS, and from a `didSet` on `MacNavigation.recordingPerson`.
  - **Menu:** in `MacCommands`, add `CommandGroup(after: .appInfo) { Button("Check for Updates…") { updater.checkForUpdates() }.disabled(!updater.canCheckForUpdates) }`.
- [ ] **Step 5: Verify the builds.**
  1. `swift test` passes.
  2. The Mac Debug build succeeds (CLAUDE.md command plus `-skipPackagePluginValidation -skipMacroValidation`).
  3. The iOS Release build (`-destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`) succeeds, and `nm -gU <iOS Luxicon.app/Luxicon> | grep -ci sparkle` prints `0`.
- [ ] **Step 6:** Commit: `Mac: Sparkle updater (asks first, defers while busy) and Check for Updates…`, naming the pinned Sparkle version in the body.

### Task 3: Build script runs locally and in CI; tag check

**Files:**
- Modify: `scripts/build-mac-app.sh`
- Create: `scripts/check-release-tag.sh`

**Interfaces:**
- Produces:
  - `scripts/check-release-tag.sh <tag>`: exits 0 and prints `<marketing> <build>` when the tag equals `mac-v<MARKETING_VERSION>-<CURRENT_PROJECT_VERSION>` from `App/project.yml`. Otherwise it exits 1 with an error naming both values.
  - `build-mac-app.sh` notarizes with `--apple-id "$AC_APPLE_ID" --team-id "$AC_TEAM_ID" --password "$AC_APP_PASSWORD"` when all three are set, and falls back to `--keychain-profile luxicon` otherwise. Its output path stays `dist/Luxicon-<m>-<b>.dmg`.

- [ ] **Step 1: Tag-check cases.** Run each against the current `project.yml` (1.0 / 18 until Task 7) and record the outputs:
  - `mac-v1.0-18` → exit 0, prints `1.0 18`
  - `mac-v1.0-19` → exit 1
  - `mac-v1.1-18` → exit 1
  - `v1.0-18` → exit 1
  - `mac-v1.0-18-rc1` → exit 1
  - an empty argument → exit 1 with usage
- [ ] **Step 2:** Write `check-release-tag.sh` with an anchored regex `^mac-v([0-9]+(\.[0-9]+)*)-([0-9]+)$`, comparing against the two values read from `App/project.yml`. Re-run Step 1. Expected: all six match.
- [ ] **Step 3: Notarization credentials.** In `build-mac-app.sh`, choose the credentials as above. Skip the `notarytool history --keychain-profile` preflight when env credentials are used. Never echo credential values.
- [ ] **Step 4: Sparkle helper check.** After the entitlements check, add a "Checking Sparkle's helpers" section. For each of `Sparkle.framework`, `Versions/B/Autoupdate`, `Versions/B/Updater.app` and `Versions/B/XPCServices/*.xpc` that exists, assert that `codesign -dv` shows the `runtime` flag and `Authority=Developer ID Application`, with team `4Z539UE4TT`.
  - If the export left any helper non-conforming, re-sign inside-out the way Oncillascope's workflow does:
    1. the XPC services, then Autoupdate, then Updater.app, then the framework;
    2. re-seal the app with `--entitlements App/LuxiconMac.entitlements`;
    3. re-assert the checks above.
- [ ] **Step 5: Local run.** Run `LUXICON_SKIP_NOTARIZE=1 scripts/build-mac-app.sh` and check that it prints the Sparkle helper checks and `entitlements: audio-input only (true)`.
  - Before the run, move the released `dist/Luxicon-1.0-18.dmg` aside, and restore it afterwards. It's the published build 18 (SHA-256 `fc19bd22…`), and this run would overwrite it.
  - Delete the local unnotarized DMG afterwards.
- [ ] **Step 6:** Commit: `Release: build script takes CI notarization creds and checks Sparkle signing; tag check`.

### Task 4: Release workflow and appcast script

**Files:**
- Create: `.github/workflows/release-mac.yml`
- Create: `scripts/make-appcast.sh`

**Interfaces:**
- Consumes:
  - `check-release-tag.sh` and env-credential `build-mac-app.sh` (Task 3)
  - secrets `DEVELOPER_ID_P12`, `DEVELOPER_ID_P12_PASSWORD`, `AC_APPLE_ID`, `AC_TEAM_ID`, `AC_APP_PASSWORD` (repo)
  - `SPARKLE_ED_PRIVATE_KEY` (environment `release`)
- Produces:
  - `scripts/make-appcast.sh`. Required env: `DMG_PATH`, `RELEASE_NOTES_MD`, `SPARKLE_BIN`, `ED_KEY_FILE`, `DOWNLOAD_URL_PREFIX`, `PAGES_DIR`. It merges the new release into `$PAGES_DIR/appcast.xml`.
  - The workflow, named `Release Mac app`.

- [ ] **Step 1: `make-appcast.sh`.** Adapt Oncillascope's `scripts/make-appcast.sh`:
  - It takes a DMG, not a zip.
  - The release-notes HTML is written beside the DMG in the work dir as `Luxicon-<m>-<b>.html`, so `generate_appcast` attaches it, and a copy goes in `$PAGES_DIR/release-notes/`.
  - `--link https://github.com/DavidsonCollege/luxicon/releases`.
  - Keep the guard that refuses to publish if the item count dropped.
  - Add a second guard: every `enclosure url` in the output starts with `$DOWNLOAD_URL_PREFIX` or an older `https://github.com/DavidsonCollege/luxicon/releases/download/mac-v` prefix. Otherwise exit 1.
- [ ] **Step 2: Workflow triggers and gate.**
  - Triggers: `push: tags: ['mac-v*']`, plus `workflow_dispatch` with a boolean input `dry_run` (default `true`).
  - One job: `runs-on: macos-26` and `environment: release`.
  - `permissions: contents: write`, and pin actions by SHA, as in Oncillascope.
- [ ] **Step 3: Build steps.**
  1. Select the newest Xcode ≥ 26, as in `release-listener.yml`.
  2. Install xcodegen (`brew install xcodegen`).
  3. On a tag push, run `scripts/check-release-tag.sh "$GITHUB_REF_NAME"`. On a dispatch, derive the tag from `project.yml` for naming only.
  4. Run `swift test`.
  5. Import the Developer ID p12 into a temporary keychain (copy the listener workflow's import step).
  6. Write the Sparkle key to `$RUNNER_TEMP` with `umask 077`.
  7. Fetch the Sparkle tools at the pinned version and verify their SHA-256.
  8. Run `bash scripts/build_mlx_metallib.sh release` if the Mac build needs it. Check what the listener workflow does.
  9. Run `scripts/build-mac-app.sh` with the `AC_*` env vars set.
- [ ] **Step 4: Publish steps**, all skipped when `dry_run` is true:
  1. Release notes come from the annotated tag message. If it's empty, use `Luxicon for Mac <m> (<b>)`.
  2. `gh release create "$TAG" dist/Luxicon-<m>-<b>.dmg --title "Luxicon for Mac <m> (<b>)" --notes-file …`.
  3. Check out `gh-pages` as a worktree, run `make-appcast.sh` with `DOWNLOAD_URL_PREFIX=https://github.com/DavidsonCollege/luxicon/releases/download/$TAG/`, then commit and push `gh-pages`.

  On a dry run, still run `make-appcast.sh` into a temp copy of `gh-pages`. Upload the DMG, the generated `appcast.xml` and the notes HTML as a workflow artifact, so the dry run proves signing and feed generation without publishing.
- [ ] **Step 5:** Validate the YAML with `actionlint` if it's installed (`brew install actionlint` is fine); otherwise `ruby -ryaml -e 'YAML.load_file(ARGV[0])' .github/workflows/release-mac.yml`. Then run `bash -n scripts/make-appcast.sh`.
- [ ] **Step 6: Local appcast check.** Run `make-appcast.sh` against an empty temp `PAGES_DIR`, using:
  - a DMG from a `LUXICON_SKIP_NOTARIZE=1` build (Task 3 Step 5 procedure, moving the released DMG aside first);
  - the Step 1 key from the keychain (`ED_KEY_FILE` unset → keychain; pass `--account edu.davidson.luxicon.mac`).

  Expected: one `<item>`, with `sparkle:version` equal to the build number and an `sparkle:edSignature`. Running it again with the output as input keeps one item, not two. Delete the temp outputs.
- [ ] **Step 7:** Commit: `Release: tag-driven Mac release workflow with Sparkle appcast on gh-pages`.

### Task 5: Docs and privacy copy

**Files:**
- Modify: `docs/privacy-policy.md` (Mac section)
- Modify: `README.md` (the Mac "Privacy" bullet near line 85, and "Privacy posture" near line 196)
- Modify: `docs/releasing.md` (Flow 3, credentials table)
- Modify: `CLAUDE.md` (release command comment, network-features sentence)

- [ ] **Step 1: Privacy line.** Add it to the privacy policy's Mac section and to both README spots: "Luxicon for Mac can check GitHub for new versions. It asks first, and the check sends nothing about you, your people, or your meetings." The iPhone copy stays unchanged.
- [ ] **Step 2: Rewrite `docs/releasing.md` Flow 3** as "tag → approve → published":
  - the bump-and-tag commands, with an annotated tag message as the release notes
  - the `release` environment and its approval click
  - what the workflow does
  - the dry run via `gh workflow run release-mac.yml -f dry_run=true`
  - that `scripts/build-mac-app.sh` stays for local, unpublished builds
  - Sparkle key location (keychain account `edu.davidson.luxicon.mac`, environment secret `SPARKLE_ED_PRIVATE_KEY`)
  - key rotation steps
  - the first-release note: build 18 users update by hand once

  Add the Sparkle key and the `release` environment as rows in the credentials table, with locations only, never values.
- [ ] **Step 3: CLAUDE.md.**
  - The Mac release comment points at the tag flow.
  - The privacy sentence names the opt-in Mac update check as a network path.
- [ ] **Step 4:** Commit: `Docs: Mac auto-update privacy line, tag-driven release flow`.

### Task 6: Local end-to-end checks

Run these against a local feed, before anything is published. Use a Debug build with `PRODUCT_BUNDLE_IDENTIFIER=edu.davidson.luxicon.mac.updatetest` and `CURRENT_PROJECT_VERSION=18` (the "old" app), copied into scratch. Also make an update DMG stamped build 99, signed with Luxicon's key via `sign_update --account edu.davidson.luxicon.mac`, and a local `appcast.xml` that lists it. Serve the feed from `127.0.0.1` (`python3 -m http.server` in a scratch dir). If Sparkle refuses a plain-http localhost feed, record that and run Steps 2–5 after the first dry run instead, against the artifact feed served over https (or fall back to Step 6 only).

- [ ] **Step 1: No request before consent.** Launch the old app twice with `-enableUpdater -updateFeedURL <local>`, and with `-storePath`/`-libraryPath` scratch dirs. Expected: the server log shows no request on the first launch; the second launch shows Sparkle's permission prompt.
- [ ] **Step 2: Update found.** With automatic checks granted, Check for Updates… shows build 99 and its notes. Install & Relaunch replaces the scratch copy, and `CFBundleVersion` reads `99`.
- [ ] **Step 3: Deferral.** Add `-recordWith "Test Person" -simulateMicrophone <synthetic wav>` and trigger a scheduled check while recording: in DEBUG, set `SUScheduledCheckInterval` low through `defaults write edu.davidson.luxicon.mac.updatetest`. Expected: no update window while the recording window is open; it appears after the recording is discarded. Then start a second recording and, during it, run a manual Check for Updates… and click Install & Relaunch. Expected: the app does not quit or relaunch while the recording window is open, the "Stop and save this recording?" prompt never appears, and the relaunch into build 99 happens right after the recording is discarded.
- [ ] **Step 4: Offline.** Stop the server, then click Check for Updates…. Expected: Sparkle's error alert, and the app keeps working (no crash, the main window still responds).
- [ ] **Step 5: Bad signature.** Flip one byte of the served DMG. Expected: Sparkle refuses to install and the scratch app stays at its old build.
- [ ] **Step 6: Cleanup.** Run `defaults delete edu.davidson.luxicon.mac.updatetest`, delete the scratch apps, DMGs and feed, and confirm `defaults read edu.davidson.luxicon.mac 2>/dev/null | grep -c SU` matches its value from before Step 1. The real app's Sparkle keys must be unchanged.

Record each step's result in the task report. No commit, unless a DEBUG hook had to change.

### Task 7: Bump to build 19 and the one-time GitHub setup (controller and JD)

These steps are outward-facing. The controller does them only after JD's go-ahead in the conversation, never as a subagent.

- [ ] **Step 1:** Set `CURRENT_PROJECT_VERSION: 19` in `App/project.yml` and commit `Bump build to 19 for the first auto-updating Mac release`.
- [ ] **Step 2 (JD go-ahead): environment.** Create the `release` environment with `gh api -X PUT repos/DavidsonCollege/luxicon/environments/release`:
  - required reviewer: JD's user id, from `gh api users/jdmills-edu -q .id`
  - deployment branch policy: custom policies `mac-v*` (tag) and `main` (branch, for dry runs)
- [ ] **Step 3 (JD go-ahead): Sparkle secret.** Export Luxicon's private key with `generate_keys --account edu.davidson.luxicon.mac -x <scratch file>`, run `gh secret set SPARKLE_ED_PRIVATE_KEY --env release < <scratch file>`, then delete the file.
- [ ] **Step 4 (JD go-ahead): Pages.** Push an orphan `gh-pages` branch holding an empty-item `appcast.xml` (a valid RSS channel with no `<item>`). Enable Pages with `gh api -X POST repos/DavidsonCollege/luxicon/pages -f 'source[branch]=gh-pages' -f 'source[path]=/'`. Confirm that `curl -fsS https://davidsoncollege.github.io/luxicon/appcast.xml` returns it.
- [ ] **Step 5: after the PR merges.** Run `gh workflow run release-mac.yml -f dry_run=true`. JD approves the run. Expected:
  - the run succeeds
  - the artifact's DMG passes `spctl -a -t open --context context:primary-signature -v` and `xcrun stapler validate`
  - its appcast has one item, whose enclosure URL is under `…/releases/download/mac-v1.0-19/`
- [ ] **Step 6 (JD go-ahead): first release.** Push the annotated tag `mac-v1.0-19`, with notes covering Cohere, the mute-crash fix, auto-update, and "if you have build 18, download this one by hand once". JD approves the run. Expected: the GitHub Release exists, and the Pages appcast lists build 19.
- [ ] **Step 7: end to end on the real feed.** Build a Release copy with bundle id `edu.davidson.luxicon.mac.updatetest` and `CURRENT_PROJECT_VERSION=18`, signed with Developer ID but not notarized, in scratch. Launch it with scratch `-storePath`/`-libraryPath` (allow Release builds to take them for this run, or use the Debug build with `-enableUpdater` and no feed override). Click Check for Updates….
  Expected: it finds build 19 on `davidsoncollege.github.io`, shows the notes, verifies the signature, installs and relaunches as 19. Then delete the scratch copy and the `edu.davidson.luxicon.mac.updatetest` defaults.
