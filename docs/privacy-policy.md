# Luxicon privacy policy

*Effective 2026-07-14; Mac section added 2026-10-23; Cohere Transcribe
download added 2026-10-24.*

Luxicon is built so that your conversations stay yours.

## What Luxicon collects

Nothing. Luxicon has no accounts, no analytics, no advertising SDKs, and no
servers. The developers receive no data of any kind from the app.

## What stays on your iPhone

Recordings, transcripts, summaries, your voice fingerprint (a numeric
embedding, not audio), your people list, and your vocabulary are stored in
the app's private container on your device. They are protected with iOS
Data Protection and are included in your standard iPhone backup (encrypted
by Apple; end-to-end encrypted if you enable Advanced Data Protection).

## What stays on your Mac (Luxicon for Mac)

The Mac app records and transcribes on the Mac itself, entirely on-device,
the same way the iPhone app does.

- Its own state (recordings, transcripts, summaries, your voice
  fingerprint, your people list, and your vocabulary) is stored in
  `~/Library/Application Support/Luxicon` in your user account.
- Finished sessions are also written to the shared `~/Luxicon` library
  folder, alongside sessions your iPhone pushes there, so local tools you
  run (such as the Luxicon MCP server for Claude) can read them.
- These are ordinary files in your user account. They are not protected by
  iOS Data Protection; turn on FileVault to encrypt them at rest. They are
  included in Time Machine backups like the rest of your home folder.
- The microphone is used only while you are recording.
- The Mac app adds no network connections beyond those listed below (it
  downloads the same speech models, plus Cohere Transcribe if you choose
  it, and URL sync works the same way when you turn it on). Sessions from your iPhone reach the Mac only through the
  opt-in Mac sync below.
- Luxicon for Mac can check GitHub for new versions. It asks first, and the check sends nothing about you, your people, or your meetings.

## Network connections the app makes

- **Speech model downloads** (required, first use): diarization models are
  fetched from Hugging Face, and on iOS 26 and later the transcription model
  is Apple's system speech asset, downloaded by the OS from Apple (with
  Apple's built-in engine off or unavailable, a transcription model is
  fetched from Hugging Face instead). No user data is sent — these are file
  downloads.
- **Cohere Transcribe model download** (optional, Mac only, off by default):
  If you choose Cohere Transcribe in Settings → Transcription, the Mac
  downloads a 1.6 GB model from Hugging Face the first time it
  transcribes. Like the other speech models, it is a file download — no user data is sent — and transcription
  with it runs entirely on the Mac.
- **Update check** (Mac only, asks first): Luxicon for Mac can check for new
  versions. The first time, it asks whether to check automatically; until you
  say yes, it checks only when you choose Check for Updates…. It reads a small
  update list from davidsoncollege.github.io and, if you accept an update,
  downloads the new version from GitHub. No profile of your Mac is sent, and
  nothing about you, your people, or your meetings.
- **Mac sync** (optional, off by default): if you pair a Mac, transcripts
  and summaries you choose to push travel over your local network to that
  Mac, encrypted with a key derived from your pairing token. They do not
  cross the internet. "Send My Voice to Mac" copies a small file with
  your voice fingerprint (not audio), your display name, and the date it was
  created, and only when you tap it.
- **Vocabulary URL sync** (optional, off by default): if you configure a
  vocabulary URL, the app fetches that file over https when opened.
- **People URL sync** (optional, off by default): if you configure a
  people-roster URL, the app fetches that file over https when opened.

That is the complete list. Without those optional features, Luxicon works
in airplane mode after the model download. (The giving screen's links —
davidson.edu/giving and the GitHub repository — open in Safari; the app
itself makes no request.)

## Sharing

Nothing leaves the app unless you export or push it. What you share — and
with whom — is up to you.

## Contact

Questions: open an issue at https://github.com/DavidsonCollege/luxicon or
email jdmills@davidson.edu.
