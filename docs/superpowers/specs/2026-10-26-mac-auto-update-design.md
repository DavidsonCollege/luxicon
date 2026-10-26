# Luxicon for Mac auto-update + tag-driven releases: design

**Goal:** Luxicon for Mac keeps itself up to date from GitHub Releases, the
way Oncillascope does. A release is cut by pushing a version tag; GitHub
Actions builds, signs, notarizes and publishes it, and updates the feed the
app checks.

**Prior art:** Oncillascope's auto-update
(`~/Documents/GitHub/Oncillascope`: `docs/superpowers/specs/2026-07-07-auto-update-design.md`,
`App/Oncillascope/UpdaterController.swift`, `.github/workflows/release.yml`,
`scripts/make-appcast.sh`, `RELEASING.md`). Follow its shape unless this
document says otherwise.

## Why
- **What JD asked for (2026-10-26):** "can we build in auto-update like we did
  for Oncillascope?", and "automatic with a version tag like oncillascope".
- **The trigger:** the first Mac release (`mac-v1.0-18`) shipped with a crash
  on real AirPods/headset mute requests (fixed on `fix/mute-handler-crash`).
  Without an updater, everyone who downloaded build 18 keeps the crash until
  they happen to download again.

## Decided

### What the person sees (JD agreed)
- **Notify and prompt; never silent.** Sparkle 2.x's standard UI: when a newer
  build exists, a window shows the release notes with Install & Relaunch.
- **Ask first.** Sparkle's standard permission prompt ("Check for updates
  automatically?"), which appears on the second launch. No automatic check
  happens before the person answers yes. Leave `SUEnableAutomaticChecks` unset
  so Sparkle asks, and set `SUAllowsAutomaticUpdates` false so Sparkle never
  offers to download and install updates without showing them.
- **Manual check:** a **Check for Updates…** item in the app menu (after About),
  disabled while Sparkle can't check. It works whether or not automatic checks
  are on, because the person asked.
- **Mac only.** The iPhone app updates through the App Store. Sparkle is linked
  into the `LuxiconMac` target only: not iOS, not LuxiconKit, not the CLI or MCP.

### Releasing (JD's call)
- **Tag-driven CI, like Oncillascope.** Pushing a tag `mac-v<marketing>-<build>`
  (the existing convention, e.g. `mac-v1.0-19`) runs a new workflow that:
  1. builds and Developer-ID signs the app,
  2. notarizes and staples the app and the DMG,
  3. signs the update for Sparkle (EdDSA),
  4. publishes the DMG to a GitHub Release for that tag,
  5. adds the release to the appcast feed on GitHub Pages.
- **The tag must match the project.** The workflow fails before building if the
  tag's marketing and build numbers don't equal `MARKETING_VERSION` and
  `CURRENT_PROJECT_VERSION` in `App/project.yml`.
- **Pushing a tag is the go-ahead to publish.** Claude pushes a release tag only
  when JD says to (the standing rule that publishing needs JD's explicit
  go-ahead still holds).

### Privacy (Claude's call; JD delegated it)
The README's privacy posture is App Store copy, so the update check is the only
new network path, and it is narrow and disclosed:
- **Hosts:** the appcast on GitHub Pages
  (`https://davidsoncollege.github.io/luxicon/appcast.xml`) and the DMG from
  GitHub Releases. Nothing else.
- **What's sent:** a plain HTTPS request. Sparkle's system profiling stays off
  (`SUEnableSystemProfiling` false), so nothing about the Mac, the person, their
  people or their meetings is sent.
- **Copy:** add one line to the Mac section of `docs/privacy-policy.md` and the
  README's privacy bullets, along the lines of: "Luxicon for Mac can check
  GitHub for new versions. It asks first and sends nothing about you or your
  meetings." The iPhone copy doesn't change. Update CLAUDE.md's
  network-features sentence to include it.

### Safety (Claude's call)
- **Never relaunch mid-work.** If an update is ready while a recording is open or
  a session is processing, postpone the relaunch until both are done
  (Sparkle's `SPUUpdaterDelegate` postpone-relaunch hook). Quitting normally
  still installs it.
- **Two signatures.** Developer ID plus notarization for Gatekeeper, and an
  EdDSA signature on each update for Sparkle, so a compromised feed can't ship
  a malicious build.

### Keys and secrets
- **Existing repo secrets the workflow reuses** (already set for the listener
  workflow): `DEVELOPER_ID_P12`, `DEVELOPER_ID_P12_PASSWORD`, `AC_APPLE_ID`,
  `AC_TEAM_ID`, `AC_APP_PASSWORD`.
- **New secret:** `SPARKLE_ED_PRIVATE_KEY`. Claude generates the key pair with
  Sparkle's `generate_keys`; the private key stays in JD's login keychain and is
  set as the secret with `gh secret set` straight from an export that is then
  deleted. It is never written into the repo or any doc.
- **Public key:** `SUPublicEDKey` in the LuxiconMac Info.plist (via
  `App/project.yml`), committed; it's public by design.
- **Rotation:** documented in `docs/releasing.md` (ship a build with the new
  public key, then sign later releases with the new private key).

### One-time setup JD does (about 5 minutes)
- Create the `release` environment with JD as required reviewer (see "Settled", item 1).
- Turn on GitHub Pages for `DavidsonCollege/luxicon` (source: the `gh-pages`
  branch, root), unless the builder can do it with `gh api` under JD's
  existing auth.
- Confirm the `SPARKLE_ED_PRIVATE_KEY` secret is set (Claude sets it with JD's
  go-ahead).

### Rollout
- **Build 19** is the first release with the updater, and carries the
  mute-crash fix and Cohere (already on main). Bump `CURRENT_PROJECT_VERSION`
  to 19 (single version train shared with iOS; that's fine).
- **People on build 18** have no updater. They download build 19 once by hand;
  the GitHub Release notes for 19 say so. After that, updates arrive in the app.
- The existing `mac-v1.0-18` release and tag stay as they are; the new workflow
  only runs on newly pushed `mac-v*` tags. Seed the appcast with build 19 only.

## Settled after the builder check

### JD's answers (2026-10-26)
1. **Releases wait for JD's approval.** Like Oncillascope, the publishing job
   runs in a GitHub `release` environment with JD (`jdmills-edu`) as required
   reviewer. Only `SPARKLE_ED_PRIVATE_KEY` is an environment secret; the
   signing and notarization secrets are repo-level, shared with the listener
   workflow. The environment's required-reviewer gate is what keeps the job
   from using any of them: it doesn't start until JD approves, so a pushed tag
   alone can't sign or publish anything. Admins can't bypass the gate
   (`can_admins_bypass` false). Creating the environment and its
   reviewer rule joins JD's one-time setup (the builder may do it with `gh api`
   if JD's auth allows; JD confirms). The listener workflow keeps working: don't
   remove the repo-level secrets it reads.
2. **Self-download only.** No Jamf or Self Service installs, so no
   managed-install mode is needed. Out of scope; revisit if that changes.
3. **The mute-crash fix lands first** as its own PR (#19). The updater work
   branches from main after #19 merges, so build 19 carries it.

### Claude's calls
4. **No update alert during a recording.** While a recording window is open,
   Sparkle's scheduled alert is held back (its gentle-reminders support in the
   standard user driver) and shown after the recording closes. A Check for
   Updates… the person starts is shown right away. A relaunch an update needs
   never goes through the "Stop and save this recording?" prompt: it is
   postponed until no recording is open and nothing is processing (decision
   above).
5. **Luxicon gets its own Sparkle key.** `generate_keys --account luxicon` (or
   equivalent), so it can't silently reuse Oncillascope's key, which is in the
   same login keychain.

## Non-goals
- Silent or forced updates.
- Delta updates.
- A beta/pre-release channel.
- Updating the iPhone app, the CLI, `luxicon-mcp` or the sync listener (the
  listener has its own installer and release flow).
- Rollback UI (older DMGs stay downloadable from Releases).

## Anti-goals
- Any network request before the person opts in, other than one they start with
  Check for Updates….
- Sending a system profile or anything about the person or their data.
- An update relaunching the app during a recording or while a meeting is being
  transcribed.
- Private keys or credential values anywhere in the repo, the docs, or a log.
- Changing what the iPhone build contains.

## Constraints
- The Mac app is unsandboxed with hardened runtime and exactly one entitlement,
  `com.apple.security.device.audio-input`; `scripts/build-mac-app.sh` asserts
  that set. Sparkle needs no new entitlement for an unsandboxed app. Keep the
  assertion.
- Sparkle's embedded helpers (Autoupdate, Updater.app, XPC services) must be
  Developer-ID signed with hardened runtime and pass notarization; verify on the
  first CI run, not by assumption.
- arm64 only, macOS 15+, Xcode 26+ (CI selects the newest installed Xcode the
  way `release-listener.yml` does; mlx-swift needs it).
- `App/project.yml` is the source of truth; the `.xcodeproj` is generated.

## Verification the builder must show
- `swift test` passes; Mac Debug and iOS Release build; the iOS binary contains
  no Sparkle symbols.
- **Before the first real release:** a dry run of the workflow (manual
  `workflow_dispatch` or equivalent) that builds, signs, notarizes and
  EdDSA-signs but publishes nothing and doesn't touch the feed.
- **End to end after build 19 is published:** a local build stamped lower (e.g.
  build 18 with Sparkle and the real feed) detects 19, shows the notes,
  verifies the signature and installs 19. It doesn't relaunch (the installed 19
  has the real bundle id and would open real data); `CFBundleVersion` is read
  from disk instead.
- **Negative test:** an update whose EdDSA signature doesn't match is refused.
- **Postpone test:** with a recording open, an available update doesn't relaunch
  the app until the recording is closed.

## Left to the builder
- Whether CI reuses `scripts/build-mac-app.sh` (with env-based notarization
  credentials) or has its own steps. One shared script is preferred.
- Whether Sparkle installs from the DMG or from a separate zip.
- Where release notes come from (tag message, a committed notes file, or the
  release body) and how they reach the appcast.
- The exact Sparkle 2.x version to pin.
- Wording polish for the privacy line and the menu item.
