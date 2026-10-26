# Releasing Luxicon — agent guide

How to ship each artifact, exactly which credentials each step uses, and
where those credentials live. Written for agents working on JD's Mac
(`W230033`); every flow below was verified working on 2026-07-09. Agent
machines may differ: this repo is also set up for releasing from `w270286`
(nothing has been released from it yet), so check which credentials actually exist on the machine you are on (the
inventory below says what to look for) before assuming a flow works.

**This repo is public. Never write credential VALUES into it — only the
locations and profile names listed here.**

There are three release surfaces:

| Artifact | Flow | Auth it uses |
|---|---|---|
| iOS app → TestFlight / App Store | `xcodebuild archive` + `-exportArchive` with `destination: upload` | Xcode's logged-in Apple account session |
| Mac listener installer → GitHub Releases | push a `listener-v*` tag (CI), or `scripts/build-installer.sh` locally | Developer ID certs + notary profile (local) / repo secrets (CI) |
| Mac app (DMG) → GitHub Releases + Sparkle appcast | push a `mac-v*` tag (CI, approved on the `release` environment); `scripts/build-mac-app.sh` for local unpublished builds | repo secrets + `release` environment secret (CI) / Developer ID Application identity + `luxicon` notary profile (local) |

---

## Credentials inventory (what exists, where it lives)

| Credential | Where | Used by | Notes |
|---|---|---|---|
| Apple account session (jdmills@davidson.edu, team `4Z539UE4TT`) | Xcode → Settings → Accounts | App Store uploads, `-allowProvisioningUpdates` signing | This is why upload "just works" — do NOT hunt for an API key; none exists on this machine. |
| "Developer ID Application" identity | login keychain | signs the listener binary and the Mac app + DMG | On W230033 the key ACL already trusts `codesign` (signs non-interactively). On a new Mac run the one-time `security set-key-partition-list` step (Flow 3) first. |
| "Developer ID Installer" identity | login keychain | signs the installer pkg | Only the Apple **Account Holder** can mint these; JD is not the Account Holder. `.p12` backups of both live in `~/Downloads/Davidson Apple Developer ID {Application,Installer}.p12` (passwords: ask JD — never write them down here). |
| Notarization credentials | keychain profile named **`luxicon`** (`xcrun notarytool … --keychain-profile luxicon`) | notarizing the installer pkg and the Mac app DMG | Backed by an app-specific password on jdmills@davidson.edu; validated against Apple 2026-07-09. Rotate at appleid.apple.com → update the profile AND the repo secret. |
| GitHub Actions secrets on `DavidsonCollege/luxicon` | repo → Settings → Secrets | CI listener releases | `AC_APPLE_ID`, `AC_TEAM_ID`, `AC_APP_PASSWORD` (notarization); `DEVELOPER_ID_P12`(+`_PASSWORD`) and `INSTALLER_ID_P12`(+`_PASSWORD`) (signing). Write-only; set with `gh secret set`. The Mac app workflow reuses `DEVELOPER_ID_P12`(+`_PASSWORD`) and the `AC_*` three. |
| Sparkle EdDSA signing key (Mac app updates) | private key: login keychain, account **`edu.davidson.luxicon.mac`** (never the default account, which may hold another app's key); CI copy: environment secret **`SPARKLE_ED_PRIVATE_KEY`** on the `release` environment (not a repo secret) | signing the appcast (`scripts/make-appcast.sh`) | Public half is `SUPublicEDKey` in `App/project.yml` (public by design). Never write the private key anywhere in the repo or a log. |
| `release` environment on `DavidsonCollege/luxicon` | repo → Settings → Environments | gates the Mac app release job; holds `SPARKLE_ED_PRIVATE_KEY` | Required reviewer: JD. The job waits for his approval click. |

Traps that have burned agents before:

- **`altool --upload-app` is dead** (Apple killed uploads in 2023). Don't
  use it; don't hunt for `iTMSTransporter` either — the exportArchive
  upload path below works.
- **"3rd Party Mac Developer Installer" is NOT "Developer ID Installer".**
  The former is App-Store-only and Xcode's UI happily creates it when you
  meant the latter. Check `security find-identity -v` for the exact string
  "Developer ID Installer" before concluding anything is missing.
- **The notary profile probe:** `xcrun notarytool history
  --keychain-profile luxicon` is the fast way to confirm credentials work.
- **Keychain P12 export is GUI-gated** — `security export` of private keys
  fails non-interactively. If a CI secret needs re-creating, base64 the
  `.p12` files from `~/Downloads` instead.
- **`error: exportArchive Failed to Use Accounts`** means the Xcode Apple
  account session is gone (it can vanish — signed out or invalidated —
  even between consecutive days). Confirm with `defaults read
  com.apple.dt.Xcode DVTDeveloperAccountManagerAppleIDLists` (empty
  `IDE.Identifiers.Prod` = no accounts). Archiving still succeeds off
  cached certs, so the failure only surfaces at upload. Fix is GUI-only:
  Xcode → Settings → Accounts, sign in jdmills@davidson.edu (password +
  2FA), then re-run the same `-exportArchive` — no need to re-archive.

---

## Flow 1: iOS app → TestFlight

### 1. Bump the build number

`App/project.yml`, project-level `settings.base.CURRENT_PROJECT_VERSION`
(single version train — the widget inherits it; a mismatched widget build
fails App Store validation). Then regenerate:

```bash
cd App && xcodegen generate
```

xcodegen is REQUIRED after any project.yml change; the .xcodeproj is
generated and gitignored.

### 2. Archive

```bash
cd App
xcodebuild -project Luxicon.xcodeproj -scheme Luxicon \
  -destination 'generic/platform=iOS' -configuration Release \
  -archivePath /tmp/Luxicon.xcarchive archive -allowProvisioningUpdates
```

Signing is automatic via the Xcode account session. The archive step signs
with an Apple Development identity; the export step re-signs for
distribution — both are normal.

### 3. Export + upload in one step

Write this `ExportOptions.plist` (scratch location is fine):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>            <string>app-store-connect</string>
	<key>destination</key>       <string>upload</string>
	<key>teamID</key>            <string>4Z539UE4TT</string>
	<key>signingStyle</key>      <string>automatic</string>
	<key>uploadSymbols</key>     <true/>
	<key>manageAppVersionAndBuildNumber</key> <false/>
</dict>
</plist>
```

```bash
xcodebuild -exportArchive -archivePath /tmp/Luxicon.xcarchive \
  -exportOptionsPlist ExportOptions.plist -allowProvisioningUpdates
```

Success looks like `Upload succeeded` + `** EXPORT SUCCEEDED **`. The build
then processes in App Store Connect for a few minutes.

### 4. Human steps (web UI only — tell JD, don't attempt)

- Assign the processed build to the TestFlight group.
- Paste the current build's notes from `marketing/app-store.md`
  ("TestFlight — What to Test") into the What to Test field.
- Export compliance: standard encryption only
  (`ITSAppUsesNonExemptEncryption=false` is already in the Info.plist).

---

## Flow 2: Mac listener installer → GitHub Releases

### Preferred: tag-driven CI

```bash
git tag listener-v1.0.1 && git push origin listener-v1.0.1
```

`.github/workflows/release-listener.yml` builds on `macos-26` (selects the
newest installed Xcode — mlx-swift needs Swift tools 6.3+), signs with both
identities from the repo secrets, notarizes, staples, and publishes the pkg
to a GitHub Release. Watch it: `gh run watch $(gh run list --workflow
release-listener --limit 1 --json databaseId --jq '.[0].databaseId')`.

To re-run after a workflow fix, move the tag:
`git tag -d TAG && git push origin :refs/tags/TAG && git tag TAG && git push origin TAG`.

### Local (validation, or when CI is down)

```bash
LUXICON_PKG_VERSION=1.0.1 \
LUXICON_SIGN_IDENTITY="Developer ID Application: The Trustees of Davidson College (4Z539UE4TT)" \
LUXICON_INSTALLER_IDENTITY="Developer ID Installer: The Trustees of Davidson College (4Z539UE4TT)" \
scripts/build-installer.sh
```

Signs, notarizes (keychain profile `luxicon`), staples, and Gatekeeper-checks
`dist/LuxiconListener-<version>.pkg`. Expected final output:
`accepted / source=Notarized Developer ID`. Without the identity env vars it
produces an unsigned pkg for local testing only. Publish manually with
`gh release create listener-vX.Y.Z dist/LuxiconListener-*.pkg`.

Notarization REQUIRES the pkg be signed — an unsigned pkg is rejected with
a confusing error, so don't submit one.

### Developer Mac installs (not a release)

`scripts/install-listener.sh` — build/sign/install/firewall/LaunchAgent in
one command. Never hand-copy the binary: the macOS firewall keys its Allow
to the code signature, and ad-hoc rebuilds get silently re-blocked
(docs/sync.md has the failure-mode table).

---

## Flow 3: Mac app (DMG) → GitHub Releases + Sparkle appcast

Tag → approve → published. `.github/workflows/release-mac.yml` ("Release Mac
app") does the build, signing, notarization, GitHub Release and appcast
update; Luxicon for Mac then offers the new version to people who have the
updater (see "First release" below).

**Publishing needs JD's explicit go-ahead.** Agents prepare the bump and
verify; they do not push a `mac-v*` tag, enable Pages, create the
environment, push `gh-pages` or set secrets on their own.

### 1. Bump and tag

Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `App/project.yml`
(single version train shared with iOS), run `cd App && xcodegen generate`,
commit, then tag the commit. The tag is `mac-v<marketing>-<build>` and must
match `App/project.yml` (`scripts/check-release-tag.sh`; the workflow refuses
a mismatch). The annotated tag message is the release notes, shown in
Sparkle's update window and on the GitHub Release (Markdown):

```bash
git tag -a mac-v1.0-19 -m "Fixes a crash when muting mid-recording.

- Cohere Transcribe is now available in Settings."
git push origin mac-v1.0-19
```

A lightweight tag works but leaves the notes as a one-line default.

### 2. Approve

The job runs in the **`release`** environment, which requires JD's approval
(Actions → the run → Review deployments → Approve). Nothing is built, and
the signing and Sparkle secrets stay unavailable, until he clicks.
The environment must exist with required reviewers before the first tag or
dispatch: if it doesn't, GitHub creates it on first use with no protection
and the job runs unapproved.

### 3. What the workflow does

On `macos-26`: checks the tag against `App/project.yml`; runs `swift test`
(then restores `Package.resolved`); imports the Developer ID identity from
the repo secrets; fetches Sparkle's tools pinned by version and SHA-256 (the
pin in the workflow must match `exactVersion` in `App/project.yml`); runs
`scripts/build-mac-app.sh` with notarization credentials from the `AC_*`
secrets; builds the release notes from the tag; runs
`scripts/make-appcast.sh` against a checkout of `gh-pages`; uploads the DMG,
`appcast.xml` and notes as a workflow artifact (kept 14 days); creates the
GitHub Release with the DMG; and pushes the new appcast and
`release-notes/` page to `gh-pages`, served at
`https://davidsoncollege.github.io/luxicon/appcast.xml`.

`scripts/make-appcast.sh` keeps every earlier version in the feed and
refuses to publish if the new feed has fewer items, drops any
`sparkle:version`, has no enclosure, or points an enclosure outside
`https://github.com/DavidsonCollege/luxicon/releases/download/`.

### Dry run

```bash
gh workflow run release-mac.yml -f dry_run=true
```

(or Actions → Release Mac app → Run workflow; `dry_run` defaults to true).
Still needs the environment approval. Builds, signs, notarizes and generates
the appcast into a temporary copy of `gh-pages`, then uploads the DMG,
appcast and notes as the `luxicon-mac-<tag>-dry-run` artifact. It creates no
release or tag and pushes nothing. A tag push always publishes.

### If a run fails

- **Before "Create GitHub Release":** nothing is published; fix and re-push
  (move the tag as in Flow 2) or dispatch again.
- **The run created the GitHub Release but the `gh-pages` push failed:**
  re-running the tag then fails at `gh release create` because the release
  exists. Either (a) publish the appcast by hand from the run's uploaded
  artifact `luxicon-mac-<tag>` (14-day retention): `gh run download <run-id>
  -n luxicon-mac-<tag>`, check out `gh-pages`, copy in `appcast.xml` and
  `release-notes/Luxicon-<m>-<b>.html` (into `release-notes/`), commit
  `Appcast: <tag>` and push; or (b) delete the release and re-run:
  `gh release delete <tag> --cleanup-tag=false` (keeps the tag), then
  re-run the failed workflow run from the Actions page. Prefer (a) if the release is already
  public: (b) rebuilds the DMG, so it replaces the one people may have
  downloaded.
- If `gh-pages` shows no change ("The appcast didn't change"), the version is
  already in the feed; check what was published before retrying.

### Local, unpublished builds

```bash
scripts/build-mac-app.sh
```

Stays for local testing and for CI to call. Runs xcodegen, archives the
`LuxiconMac` scheme (arm64 only), exports with
`packaging/mac-export-options.plist`, verifies the signature, the
`audio-input` entitlement, Sparkle's nested helpers (hardened runtime,
Developer ID authority) and that the MLX `*.metallib` made it into the app's
Resources, then notarizes and staples the **app** (zipped with `ditto`), so
a copy dragged out of the DMG validates offline. Then it builds
`dist/Luxicon-<marketing>-<build>.dmg` (app + Applications symlink), signs
the DMG, notarizes and staples it too, and Gatekeeper-checks both. Expected
final output: `accepted / source=Notarized Developer ID` for both. It warns
(doesn't fail) on a dirty git tree.

Locally it uses (locations only):

- **"Developer ID Application" identity** in the login keychain. The
  LuxiconMac target signs it manually (team `4Z539UE4TT`, no provisioning
  profile), so the Xcode Apple account session is NOT needed for this flow.
  One-time per Mac, so codesign never prompts: run
  `security set-key-partition-list -S apple-tool:,apple:,codesign: -s ~/Library/Keychains/login.keychain-db`
  in Terminal.app (it asks for the login password; agent shells can't pass it).
- **Notary keychain profile `luxicon`.** If missing, the script fails fast.
  Create it in Terminal.app (it prompts for an app-specific password; never
  put it in the repo or a command line an agent sees):
  `xcrun notarytool store-credentials luxicon --apple-id <account> --team-id 4Z539UE4TT`.
  Probe: `xcrun notarytool history --keychain-profile luxicon`.

`LUXICON_SKIP_NOTARIZE=1 scripts/build-mac-app.sh` produces a signed but
NOT notarized DMG for local testing. Never publish that one.

If export fails with `Failed to Use Accounts`, see the trap above (that is
the Xcode account session; unexpected for this flow since signing is manual,
so stop and report).

### Sparkle signing key

- **Private key:** JD's login keychain, account `edu.davidson.luxicon.mac`.
  `scripts/make-appcast.sh` reads it from there when run locally (no
  `ED_KEY_FILE`). Always pass `--account edu.davidson.luxicon.mac` to
  Sparkle's `generate_keys` / `generate_appcast`; the default account may
  hold another app's key.
- **CI copy:** environment secret `SPARKLE_ED_PRIVATE_KEY` on `release`.
  The workflow writes it to a temp file only after the build and deletes it
  at the end.
- **Public key:** `SUPublicEDKey` in `App/project.yml`.

**Rotating the key.** Installed apps only accept updates signed by the
public key they carry, so rotate in two releases:

1. Generate a new pair under a new keychain account (`generate_keys
   --account <new>`); set the new public key as `SUPublicEDKey` in
   `App/project.yml`.
2. Ship a release carrying the new public key, still signed with the OLD
   private key (the old secret stays in `SPARKLE_ED_PRIVATE_KEY` for this
   run). Sparkle accepts it because the old key signed it, and installed
   apps now hold the new key.
3. Replace `SPARKLE_ED_PRIVATE_KEY` on `release` with the new private key
   (set from a temporary export, then delete the export), and update
   `KEYCHAIN_ACCOUNT` in `scripts/make-appcast.sh` to the new account.
   Later releases are signed with the new key.
4. Keep the old key until nobody is expected to update from a build that
   predates the rotation.

### First release (build 19)

Build 18 has no updater. People on it download build 19 once by hand from
the GitHub Releases page; from then on updates arrive in-app. The
`mac-v1.0-18` release and tag stay as they are.

## Device installs (testing, not a release)

```bash
cd App && xcodebuild -project Luxicon.xcodeproj -scheme Luxicon \
  -destination 'generic/platform=iOS' -configuration Release \
  -allowProvisioningUpdates build
xcrun devicectl list devices   # find the iPhone's identifier
xcrun devicectl device install app --device <UDID> \
  ~/Library/Developer/Xcode/DerivedData/Luxicon-*/Build/Products/Release-iphoneos/Luxicon.app
```

Use **Release** — Debug device builds depend on the stub-executor debug
dylib and won't launch from a direct install.

---

## Screenshot refreshes

Seeded demo data + the `-route` launch argument (DEBUG builds only) drive
the app in the simulator; see the App Store sets in `marketing/screenshots/`
(iPhone slot is 1284×2778 — capture on a current device and
`sips --resampleWidth 1284` + center-crop; iPad Pro 13-inch is native
2064×2752). Status bar: `xcrun simctl status_bar <udid> override --time "9:41"
--batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4`.
Seeding = write a `store.json` into the app container's `Documents/`
(`xcrun simctl get_app_container <udid> edu.davidson.luxicon data`); a
legacy `syncToken` field in it migrates into the keychain on first launch
and switches on all the Mac Sync UI.
