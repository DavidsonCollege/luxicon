# Luxicon for Mac — design

**Goal:** JD records an in-person 1-on-1 on a MacBook using the built-in mic.
The Mac transcribes and summarizes it on-device and files it into the same
`~/Luxicon` library the phone pushes into, so the MCP server sees both. The
app ships as a Developer ID–signed, notarized download on GitHub Releases,
and its layout is built for desktop windows rather than a stretched phone.

## Decided with JD

- **Use case:** in-person meetings only. The laptop mic hears both people.
  There is no system-audio or video-call capture.
- **One shared library in `~/Luxicon`.** Sessions recorded on the Mac are
  written there as standard session export files, next to phone pushes.
  The Mac app shows both, as one library.
- **People are set up again on the Mac.** There is no people sync from the
  phone (the existing https people-URL sync works on the Mac as it does on
  the phone).
- **The voice print moves phone → Mac** with a "Send my voice to Mac" button
  on the phone that uses the existing Mac-sync pairing.
- **Distribution:** Developer ID–signed, notarized, stapled download on
  GitHub Releases, next to the listener pkg. No Mac App Store.

## Non-goals

- Video-call / system-audio capture.
- Mac → phone sync of any kind (sync stays one-directional by design).
- Editing, re-processing, or deleting phone-pushed sessions from the Mac.
- Folding the sync listener into the app. The listener stays its own
  LaunchAgent and pkg; the app only reads its token and output.
- Mac App Store, sandboxing, Intel Macs (MLX needs Apple Silicon).
- Widgets, Live Activities, App Intents/Shortcuts, background GPU tasks on Mac.
- Auto-update (Sparkle etc.). New versions are a manual download for now.

## Anti-goals (would be a failure even if it "works")

- The Mac app damages or rewrites files the phone or listener own:
  phone-pushed session files, `.sync-token`, the MCP's view of the library.
- `store.json` or audio lands in `~/Documents` (the non-sandboxed default
  for `.documentDirectory`) or anywhere other than Application Support.
- A new network path beyond the README's privacy posture: on-device
  processing, LAN-only sync, https-only vocabulary/people URL sync, and the
  existing first-run speech-model download.
- The iOS app regresses: any change to shared code must keep the iOS build
  and its `store.json` back-compat intact.
- A phone-sized column floating in a large window.

## Architecture (my calls)

### Native macOS target, not Mac Catalyst

A second xcodegen target, `LuxiconMac` (`platform: macOS`, deployment target
macOS 15.0, arm64 only), in `App/project.yml`. It shares `App/Sources` with
the iOS target and excludes the iOS-only files:
`ContinuedProcessing.swift`, `RecordingActivityController.swift`,
`LuxiconIntents.swift`, `App/Shared`, and the widget target. Mac-only code
goes in `App/MacSources/`. Small platform differences inside shared files
use `#if os(iOS)` / `#if os(macOS)`, following the precedent in `Recorder.swift`.

Why native over Catalyst: Catalyst keeps iOS control sizing, `fullScreenCover`
semantics, and iOS-style navigation, which is the "stretched phone" anti-goal.
Most of the app is plain SwiftUI plus LuxiconKit, and LuxiconKit already
builds for macOS (the CLI), so the port is contained.

- Bundle ID `edu.davidson.luxicon.mac`, team `4Z539UE4TT`. Shares
  `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` with the iOS app.
- Hardened runtime. Entitlements: `com.apple.security.device.audio-input`
  (required for mic access under hardened runtime). No sandbox. Drop the
  iOS-only entitlements.
- Info.plist: `NSMicrophoneUsageDescription` reworded for the Mac ("audio
  never leaves this Mac"), plus `LSMinimumSystemVersion`, `LSApplicationCategoryType`
  (productivity). `NSLocalNetworkUsageDescription` is not needed: the Mac app
  makes no LAN connections.
- MLX Metal shaders: confirm `xcodebuild` compiles mlx-swift's metallib into
  the macOS app bundle the way it does for iOS. If it does not, the build
  script runs `scripts/build_mlx_metallib.sh` and copies the output into the
  bundle before signing.

### Where things live on the Mac

| Data | Location |
|---|---|
| App state (`store.json`: people, my voice, settings, Mac sessions) | `~/Library/Application Support/Luxicon/` |
| Mac recordings (WAV) and profile photos | `~/Library/Application Support/Luxicon/audio/`, `…/photos/` |
| Finished Mac sessions (shared library) | `~/Luxicon/<Person> <yyyy-MM-dd> <id8>.json` |
| Phone-pushed sessions | `~/Luxicon/` (written by the listener, read-only to the app) |
| Pushed voice print | `~/Luxicon/luxicon-voiceprint.json` |
| Secrets (vocab/people URL headers) | macOS Keychain |

`Store.documentsURL` becomes a platform switch; everything else derives from
it. Create `~/Luxicon` if it doesn't exist (the listener may not be installed).

Keychain: `KeychainStore` works on macOS. Use the login keychain (no
`kSecUseDataProtectionKeychain`, which would need a keychain-access-groups
entitlement and a provisioning profile). The iOS-only accessibility constant
stays iOS-only.

### Mac sessions in the shared library

A Mac session lives in `store.json` like a phone session: status, audio,
reprocess, delete. When it reaches `.ready`, and again whenever its summary
or transcript changes, the app writes the standard single-session export
envelope (`TranscriptExport.json(transcript, summary:)`) to `~/Luxicon`. It
uses the same filename scheme the phone uses for pushes
(`MacSyncService.swift:51`), written atomically. Deleting a Mac session in the app
deletes its library file too, after a confirmation that says the file goes
from `~/Luxicon` (and from what Claude/MCP can see).

**Telling Mac files from phone files (my call):** neither `MeetingTranscript`
nor the export envelope has an id today. `TranscriptExport.json` gains two
optional parameters, `sessionId: UUID?` and `source: String?`, and emits them
only when they are set. The Mac app always writes `"source": "mac"` and its
session UUID. The phone does not change: its files lack both keys and count
as iPhone sessions. Unknown keys are ignored by every existing decoder (the phone,
`TranscriptLibrary.parse`, and older MCP builds), so this needs no phone
release or listener update. `TranscriptLibrary.Session` exposes the two fields,
decoded leniently. Add LuxiconKit tests covering an envelope with them, an
envelope without them, and the existing fixtures.

Each Mac `SessionRecord` also records the filename it last wrote (new
optional `libraryFileName`), so a rename or re-export rewrites the same
file. The app lists phone-pushed sessions by loading `~/Luxicon` with
`TranscriptLibrary.load(from:)` and dropping any whose `sessionId` matches
a Mac session in `store.json`, so Mac sessions don't appear twice. A file
with `source: "mac"` but no matching record is shown as a Mac session that
can only be read or deleted. That happens only if `store.json` was lost.
The source badge and the read-only rule key off `source`, not the filename.
Phone sessions are read-only: transcript, summary, copy/export, but no
reprocess, rename, or delete. A file watcher on `~/Luxicon` (FSEvents or
`DispatchSource`) refreshes the list when the listener writes a push, so a
phone push appears without restarting.

**People merge (my call):** the sidebar shows the Mac's own people, plus
"library-only" people derived from phone-pushed sessions, matched by name
(case-insensitive). A library-only person shows their phone sessions and can
be promoted to a real Mac person with one click ("Add to People"), which
lets you record with them.

### Voice print transfer

There is no wire-protocol change and no listener change. The existing listener
already writes any pushed file into `~/Luxicon`, and
`TranscriptLibrary.parse` returns nothing for JSON without a transcript.
The MCP server and library scan therefore ignore the file.

- **Phone (iOS app):** "Send my voice to Mac" in My Voice → Mac sync, shown
  when a pairing token is set and a voice print exists. It sends a `Push` with
  `filename: "luxicon-voiceprint.json"` and a payload envelope
  `{ "kind": "voiceprint", "schemaVersion": 1, "name": <myName>,
  "createdAt": <date>, "embedding": [Float] }`. The success and failure UI
  follow the existing push outcome patterns.
- **Shared code:** put the envelope type in LuxiconKit (`VoicePrintFile`,
  Codable, with encode and decode tests) so both apps agree on it.
- **Mac:** on launch and whenever the watcher sees the file change, if it
  holds a voice print that differs from the current one, show a non-modal
  banner in My Voice ("Voice print from iPhone, received <date>: Use it").
  The user confirms. It never silently replaces an enrolled voice. The Mac
  also supports enrolling directly with the laptop mic, the same flow as the
  phone. The UI notes that a voice print recorded on this Mac's mic
  can match better than one from the phone.
- Settings → Mac Sync on the Mac shows whether the listener is running
  (port 51234 listening, or the LaunchAgent loaded) and the pairing token
  from `~/Luxicon/.sync-token` with a Copy button. Pairing then needs no
  Terminal. If the listener is absent, link to the installer download.

### Recording on the Mac

- `Recorder` already guards `AVAudioSession` behind `#if os(iOS)`. On the Mac
  it uses `AVAudioEngine` on the default input device. Replace the UIKit
  lifecycle observers with macOS equivalents. Handle a device change
  mid-recording (AirPods connect, USB mic unplugged) with
  `AVAudioEngineConfigurationChange`: restart on the new default device
  and keep writing to the same file, as the iOS interruption path does.
- The record window shows which input device is in use. A device picker is
  out of scope for v1.
- Keep the Mac awake while recording and processing:
  `ProcessInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated])`,
  replacing the iOS `isIdleTimerDisabled` use in `SessionProcessing.swift`.
  Closing the lid still sleeps the Mac, so show a one-line warning in the
  record window: "Keep the lid open; closing it stops recording."
- If the Mac goes to sleep mid-recording anyway, the WAV written so far must
  be finalized and recoverable as a `.recorded` session on wake or next
  launch. Nothing is lost.
- Mic permission is requested on first record or enrollment. If it is denied,
  show a button that opens System Settings → Privacy & Security → Microphone
  (`x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone`).
- Live captions (`LiveCaptioner`) and off-the-record work as on iOS. Replace
  the UIApplication background notifications with `NSApplication` equivalents.
  On the Mac, "background" means the app is hidden, not suspended, so captioning can
  keep running.
- Processing on the Mac is not killed in the background. The iOS
  cancel-on-background path (`handleScenePhaseChange`) is iOS-only.

### Desktop layout

Root is a three-column `NavigationSplitView`:

1. **Sidebar:** People (Mac people and library-only people, with a
   last-session date and a session count), plus fixed entries for
   "All Sessions" and "Vocabulary". The record button is at the top of the sidebar.
2. **Content:** the selected person's sessions (date, duration, status,
   summary first line, and a source badge: Mac or iPhone), with the person's
   context field available in a header or inspector.
3. **Detail:** session detail: summary, then transcript with speaker labels
   and timestamps. Long transcripts scroll independently, and the text column
   has a comfortable reading width (about 70 characters, max ~760 pt) instead of
   spanning a 2560-pt window.

Other Mac conventions:

- **Recording** opens in its own window (`Window` scene) or a sheet sized for
  desktop, not `fullScreenCover`. It shows timer, level meter, live captions,
  off-the-record, and Stop.
- **Settings scene (⌘,):** My Voice, Summaries, Vocabulary/People URL sync,
  Mac Sync (listener status and token), About/Giving, Acknowledgements.
  This reuses the existing views as `Form`s with `.formStyle(.grouped)`.
- **Menus and shortcuts:** ⌘N New Recording (asks for the person if none is
  selected), ⌘. to stop while the recording window is key (no bare-key stop: a stray Space must never end a recording), ⌘F search
  sessions (use `TranscriptLibrary.search`), ⌘C/⌘⇧C copy transcript or summary.
  Use `NSPasteboard` instead of `UIPasteboard`. Delete key deletes a Mac session
  (with confirmation).
- **Window sizing:** main window minimum ~900×600, default ~1200×800, with the
  state restored. The sidebar collapses cleanly at the minimum.
- **Onboarding** is a Mac-sized sheet over the first window (not
  `fullScreenCover`) with three steps: your name, mic permission, then voice
  (import from iPhone if the voiceprint file exists, enroll here, or skip).
- `AvatarView` uses `NSImage` on macOS (a small `PlatformImage` shim).
  `PhotosPicker` exists on macOS, and a file importer is an acceptable
  alternative.

### Desktop resolution testing

There are no app-target tests (per CLAUDE.md), so verify visually and
record the results in the plan's final task:

- Extend the existing `-route` launch-argument hooks to the Mac app, so
  each screen (person list, session detail, recording, settings,
  onboarding) can be opened directly, using fixture data from a scratch
  library folder (`-libraryPath`, `-storePath` overrides) so tests never
  touch JD's real `~/Luxicon`.
- Capture each screen at these window sizes: 900×600 (the minimum), 1280×800,
  1512×982 (14" MBP default), 1920×1080, 2560×1440. Capture each in light and dark
  mode with `screencapture -l <windowID>`. JD's built-in display is 3024×1964 Retina, and
  there's a 5K external, so check both 1x and 2x scaling where they apply.
- Check for: no truncated controls, no horizontal scroll, readable transcript
  width at the largest size, sidebar behavior at the minimum, Dynamic Type
  is N/A, VoiceOver labels present on the record controls, and keyboard
  focus reachable for primary actions.
- End to end on this Mac: record a real two-person conversation of 2 minutes
  or more, process it, confirm speaker labels with an imported phone voice
  print and again with a Mac-enrolled one, confirm the file appears in
  `~/Luxicon`, and confirm `luxicon-mcp` lists it. Then send the voice print
  from the phone with the installed listener and confirm the banner appears.

### Build, sign, notarize, release

New `scripts/build-mac-app.sh`, modeled on `build-installer.sh`:

1. `xcodegen generate`.
2. `xcodebuild archive -scheme LuxiconMac -configuration Release`.
3. `-exportArchive` with `method: developer-id`, signing with the
   "Developer ID Application" identity already in the login keychain
   (hardened runtime, timestamp).
4. Package as a DMG (`hdiutil`) with the app and an /Applications symlink,
   then sign the DMG.
5. `xcrun notarytool submit --keychain-profile luxicon --wait`, then
   `xcrun stapler staple` the DMG.
6. Verify with `spctl -a -vv -t install` on the DMG and `spctl -a -vv` on the
   app, and `codesign --verify --deep --strict`.

**Versioning (my call):** the Mac app stays on the shared train
(`MARKETING_VERSION` 1.0, shared `CURRENT_PROJECT_VERSION`). Release names use
both numbers, `<marketing>-<build>`, so they never collide.
A Mac release that includes code changes bumps the shared build number, as
an iOS release would. Build numbers only need to increase.

Output: `dist/Luxicon-<marketing>-<build>.dmg` (e.g. `Luxicon-1.0-18.dmg`).
Publishing the GitHub release (tag `mac-v<marketing>-<build>`, e.g.
`mac-v1.0-18`) is a separate step and needs JD's explicit go-ahead,
because the repo is public. A CI workflow mirroring `release-listener.yml`
is out of scope for v1.

Update `docs/releasing.md` (new flow row and section), `CLAUDE.md` (Mac
target commands), `README.md` and `docs/privacy-policy.md` (the Mac app has
the same on-device posture), and `docs/sync.md` (voice-print transfer).

**Voice-print disclosure (my call):** a voice print is biometric data, and
today's privacy copy says only transcripts sync. The README privacy section,
`docs/privacy-policy.md`, and the iOS `NSLocalNetworkUsageDescription` will say
that Mac sync can also send your own voice print, only when you tap "Send my
voice to Mac". This ships with the next iOS build that includes the button.

## Left to the builder

- How to factor shared views versus Mac-specific views. Prefer reusing
  existing views with small `#if os` branches. Write Mac-only containers
  where navigation differs.
- The exact file-watcher API, banner styling, and sidebar row design (follow the
  existing visual language and DavidsonRed accent).
- Whether recording uses a separate `Window` or a sheet. Pick whichever
  tests better at 900×600 and 2560×1440.
- Listener-running detection method.
- Splitting the work into PRs (suggested: shared-code portability →
  Mac target and layout → voice-print transfer → build/sign script → docs).
