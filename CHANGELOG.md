# Changelog

## 1.0 (build 6) — unreleased

Pre-release hardening pass (QA audit 2026-07-09):

- Mac sync now works on device: local-network permission keys were missing,
  and an unreachable Mac hung pushes forever instead of timing out.
- A phone call mid-recording no longer silently ends capture; recording
  resumes after the interruption and the UI says so.
- Microphone-permission denial is handled instead of crashing.
- A corrupt session library is quarantined instead of being silently
  overwritten; save failures are surfaced.
- The Mac-sync pairing token and vocabulary auth headers moved to the
  Keychain; library files get stronger data protection.
- Long recordings no longer hold the whole session in memory.
- Re-transcribe works; duplicate model downloads prevented; CLI --vocab is
  honored; vocabulary sync is https-only; sync listener caps frame sizes.
- Widget extension version now matches the app (App Store upload fix).
- README/App Store copy now disclose the opt-in sync features; added
  privacy policy, sync guide, SECURITY.md.

New in this build:

- Session headlines are now short topic lists (no names — the session
  already sits under a person).
- Per-person context: a free-text field on each person (and an "About you"
  field in My Voice) gives the summarizer background it can use.
- People import/export and URL sync, modeled on vocabulary sync but
  merge-only: syncing adds and updates people, never removes anyone.
- Mac sync status on every session (shown only when Mac Sync is paired):
  rows get a small synced/failed/pending mark, and session detail gets a
  Mac Sync section with the exact error message and a retry button. Failed
  pushes retry automatically when the app foregrounds.
- `scripts/install-listener.sh` builds, signs, installs, and firewall-allows
  the Mac listener; the stable signature keeps the firewall Allow across
  rebuilds (unsigned builds were silently re-blocked, timing out every
  push). The listener log now flushes live under launchd.

Review fixes on the above:

- Push reliability: pushes re-read the session at send time (a retry sweep
  could push minutes-stale content and mark it fresh), one session can't
  push twice concurrently, and a push outcome recorded mid-transcription is
  no longer reverted when transcription finishes. Re-transcribing, renaming
  a speaker, or regenerating a summary resets the sync badge to pending.
- Summarizer context from people sync is length-capped and fenced as
  untrusted in the prompt; sync requests refuse redirects to other hosts so
  auth headers can't leak; a synced entry matching your own name updates
  My Voice context instead of duplicating you; context edits persist on
  backgrounding.
- Privacy polish: copied transcripts are local-only and expire after 10
  minutes; temp export files are deleted when views close; the Live
  Activity redacts the person's name on the locked lock screen.
- Robustness: sub-second recordings can't be saved, empty speaker renames
  are ignored, audio decoding no longer blocks the UI, MCP returns both
  sessions when two 1-on-1s share a day, WAV headers clamp instead of
  crashing past 4 GB, and the install script pre-authorizes sudo, prefers
  a Developer ID identity, and creates the LaunchAgent on first run.
- Mac listener installer: `scripts/build-installer.sh` produces a
  double-clickable pkg (binary → /usr/local/bin, all-users LaunchAgent,
  firewall Allow and immediate start in the postinstall, uninstaller
  included), signed/notarized/stapled when the Developer ID Installer
  identity is present; a `listener-v*` tag builds and publishes it to
  GitHub Releases via CI.

Open-source hygiene:

- Acknowledgements screen in the app (My Voice → Open-Source
  Acknowledgements) lists every dependency and model license; it and
  `THIRD-PARTY-NOTICES.md` are both generated from `Package.resolved` by
  `scripts/generate-notices.sh` so the two can't drift.
- Added CONTRIBUTING.md (dev setup, testing expectations) and
  CODE_OF_CONDUCT.md (Contributor Covenant), plus GitHub issue and pull
  request templates.
- The Mac listener installer package now bundles
  THIRD-PARTY-NOTICES.md alongside the binary.

## 1.0 (builds 1–5)

Initial development: on-device diarized transcription, speaker enrollment,
summaries, live captions, vocabulary, Siri/App Intents, widgets, MCP
server, Bonjour/LAN Mac sync.
