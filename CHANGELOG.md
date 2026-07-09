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

## 1.0 (builds 1–5)

Initial development: on-device diarized transcription, speaker enrollment,
summaries, live captions, vocabulary, Siri/App Intents, widgets, MCP
server, Bonjour/LAN Mac sync.
