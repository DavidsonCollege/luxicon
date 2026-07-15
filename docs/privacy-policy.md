# Luxicon privacy policy

*Effective 2026-07-14.*

Luxicon is built so that your conversations stay yours.

## What Luxicon collects

Nothing. Luxicon has no accounts, no analytics, no advertising SDKs, and no
servers. The developers receive no data of any kind from the app.

## What stays on your iPhone

Recordings, transcripts, summaries, your voice fingerprint (a 256-number
embedding, not audio), your people list, and your vocabulary are stored in
the app's private container on your device. They are protected with iOS
Data Protection and are included in your standard iPhone backup (encrypted
by Apple; end-to-end encrypted if you enable Advanced Data Protection).

## Network connections the app makes

- **Speech model downloads** (required, first use): diarization models are
  fetched from Hugging Face, and on iOS 26 and later the transcription model
  is Apple's system speech asset, downloaded by the OS from Apple (with
  Apple's built-in engine off or unavailable, a transcription model is
  fetched from Hugging Face instead). No user data is sent — these are file
  downloads.
- **Mac sync** (optional, off by default): if you pair a Mac, transcripts
  and summaries you choose to push travel over your local network to that
  Mac, encrypted with a key derived from your pairing token. They do not
  cross the internet.
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
