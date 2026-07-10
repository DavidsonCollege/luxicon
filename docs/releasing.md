# Releasing Luxicon — agent guide

How to ship each artifact, exactly which credentials each step uses, and
where those credentials live. Written for agents working on JD's Mac
(`W230033`); every flow below was verified working on 2026-07-09.

**This repo is public. Never write credential VALUES into it — only the
locations and profile names listed here.**

There are two release surfaces:

| Artifact | Flow | Auth it uses |
|---|---|---|
| iOS app → TestFlight / App Store | `xcodebuild archive` + `-exportArchive` with `destination: upload` | Xcode's logged-in Apple account session |
| Mac listener installer → GitHub Releases | push a `listener-v*` tag (CI), or `scripts/build-installer.sh` locally | Developer ID certs + notary profile (local) / repo secrets (CI) |

---

## Credentials inventory (what exists, where it lives)

| Credential | Where | Used by | Notes |
|---|---|---|---|
| Apple account session (jdmills@davidson.edu, team `4Z539UE4TT`) | Xcode → Settings → Accounts | App Store uploads, `-allowProvisioningUpdates` signing | This is why upload "just works" — do NOT hunt for an API key; none exists on this machine. |
| "Developer ID Application" identity | login keychain | signs the listener binary | Key ACL already trusts `codesign` — signs non-interactively. |
| "Developer ID Installer" identity | login keychain | signs the installer pkg | Only the Apple **Account Holder** can mint these; JD is not the Account Holder. `.p12` backups of both live in `~/Downloads/Davidson Apple Developer ID {Application,Installer}.p12` (passwords: ask JD — never write them down here). |
| Notarization credentials | keychain profile named **`luxicon`** (`xcrun notarytool … --keychain-profile luxicon`) | notarizing the installer pkg | Backed by an app-specific password on jdmills@davidson.edu; validated against Apple 2026-07-09. Rotate at appleid.apple.com → update the profile AND the repo secret. |
| GitHub Actions secrets on `DavidsonCollege/luxicon` | repo → Settings → Secrets | CI listener releases | `AC_APPLE_ID`, `AC_TEAM_ID`, `AC_APP_PASSWORD` (notarization); `DEVELOPER_ID_P12`(+`_PASSWORD`) and `INSTALLER_ID_P12`(+`_PASSWORD`) (signing). Write-only; set with `gh secret set`. |

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
