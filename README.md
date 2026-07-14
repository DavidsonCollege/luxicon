# Luxicon

<img src="App/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="128" align="right" alt="Luxicon app icon: a wildcat and a colleague in a 1-on-1 across a café table">

**On-device 1-on-1 recorder for managers.** Record a sit-down with a direct
report on your iPhone, get a speaker-labeled transcript that stays on your
devices, and export it as clean markdown or JSON for the AI assistant of your
choice — performance summaries, check-in prep, longitudinal review.

No cloud APIs. No per-minute pricing. No audio leaving the phone.

Luxicon is a free, open-source service of
[Davidson College](https://www.davidson.edu), built by the college's
Technology & Innovation team. If you like what you see, consider
[giving to Davidson](https://www.davidson.edu/giving).

## How it works

1. **Enroll your voice once** (~15 seconds of reading aloud). Luxicon stores a
   256-number voice fingerprint — not the audio.
2. **Record a 1-on-1** with the phone on the table. When you stop, the app
   diarizes the conversation (who spoke when), transcribes each speaker turn,
   and matches your enrolled voice — so the transcript comes out labeled
   *you* and *them* automatically.
3. **Export** timestamped markdown (or structured JSON) with talk-time stats,
   ready to paste into Claude, ChatGPT, or your HR system's AI check-in notes.

All inference runs on the Apple Neural Engine / GPU via
[soniqo/speech-swift](https://github.com/soniqo/speech-swift):

- **Diarization** — Pyannote segmentation + WeSpeaker embeddings with
  constrained clustering, capped to 2 speakers for 1-on-1s
- **Transcription** — NVIDIA Parakeet TDT (CoreML)
- **Speaker ID** — WeSpeaker enrollment matching (cosine similarity)

Models download from Hugging Face on first use and are cached on-device:
~700 MB for transcription + diarization, ~400 MB more for on-device
summaries, plus a small live-caption model (~1.2 GB total if you use
everything).

Measured June 2026 on an M-series Mac (release build): a 50-second
two-speaker meeting diarizes, transcribes, and speaker-matches in 4.6 s
(0.09× real-time), with every turn correctly attributed. iPhones with recent
A-series chips should land within a few multiples of that. Reproduce with
`luxicon-cli <any two-speaker wav>` — it prints the real-time factor.

## Structure

```
Sources/LuxiconKit/     Core pipeline (platform-neutral Swift package)
  MeetingPipeline.swift   diarize → per-turn ASR → speaker naming
  Models.swift            transcript, turns, stats, enrollment types
  Export.swift            markdown + JSON export
  MeetingSummarizer.swift on-device LLM summaries (Qwen3.5, MLX)
  Vocabulary*.swift       user glossary + ASR correction pass
  LuxiconSync.swift       LAN sync protocol (TLS-PSK) + SyncPusher.swift
Sources/LuxiconCLI/     macOS command-line harness
Sources/LuxiconMCP/     MCP server + `listen` sync receiver
App/                    iOS app (SwiftUI, generated with xcodegen)
  Widgets/                Control Center control + Live Activity
Tests/                  swift-testing unit tests (offline, no models)
packaging/              Mac listener installer pkg (scripts/build-installer.sh)
```

## Building

### iOS app

Requires **Xcode 26+** to build (the background-processing code uses iOS 26
SDK symbols, runtime-gated so it runs fine on iOS 18+ devices). Target
device: iOS 18+, A13 or later recommended. The Swift package (CLI, MCP
server) builds with Xcode 16+.

```bash
brew install xcodegen
cd App && xcodegen generate
open Luxicon.xcodeproj   # set your signing team, build & run on device
```

Note: diarization uses MLX (Metal) and does not run in the iOS Simulator.
Use a physical device, or the CLI on a Mac.

### macOS CLI

```bash
swift build
bash scripts/build_mlx_metallib.sh debug   # compile MLX Metal shaders
.build/debug/luxicon-cli meeting.wav \
    --enroll "Your Name=enrollment.wav" \
    --title "Weekly 1:1" --out ./out
```

First run may require the Metal toolchain: `xcodebuild -downloadComponent MetalToolchain`.

Other flags: `--vocab "Choreo, OKR"` / `--vocab-file terms.json` ground
transcription in your jargon, and
`luxicon-cli push export.json --token <token> [--host <mac-ip>]` exercises
the same sync path the app uses.

### MCP server (query transcripts from Claude)

`luxicon-mcp` serves a local folder of Luxicon exports to MCP clients
(Claude Desktop, Claude Code) over stdio — retrieval only; the reasoning is
the client's job. Export sessions from the app (per-session JSON or a
person's Full History JSON) into `~/Luxicon` (or pass `--library <dir>`;
subfolder names label sessions that lack a person).

```bash
swift build -c release
claude mcp add luxicon -- "$PWD/.build/release/luxicon-mcp"
```

Tools: `list_people`, `list_sessions`, `get_transcript`, `get_summary`,
`search_transcripts`, `talk_time_trends`. The library is re-scanned on every
call, so newly pushed or AirDropped exports appear immediately.

### Mac sync (push from the phone)

Instead of AirDropping exports, install the listener and pair the phone
once. The easy way is the notarized installer from the
[Releases page](https://github.com/DavidsonCollege/luxicon/releases) —
download, double-click, one admin prompt, done. From a checkout,
`scripts/install-listener.sh` does the same via a LaunchAgent.

```bash
cat ~/Luxicon/.sync-token       # pairing token, created on first listen
# iPhone: My Voice → Mac sync → enter the token
```

Transcripts you push (or every new one, with auto-push) land in `~/Luxicon`
as JSON, ready for the MCP server. Connections are TLS-PSK on your local
network; see [docs/sync.md](docs/sync.md) for pairing details and
troubleshooting.

### Tests

```bash
swift test
```

## Consent

Recording conversations requires consent — in many jurisdictions, from **all**
parties. Luxicon shows a reminder in the recording UI, but complying with your
local law and your organization's policy is on you. Be the kind of manager who
asks first.

## Privacy posture

- Audio, transcripts, and voice fingerprints are stored in the app's Documents
  container on-device. They are included in your normal iPhone backup
  (encrypted by Apple; end-to-end if you use Advanced Data Protection) — so a
  restored phone keeps your library.
- Out of the box, the only network traffic is the model download from
  Hugging Face (no user data attached).
- Opt-in features create additional traffic, all under your control:
  - **Mac sync** — when you pair a Mac, transcripts and summaries you push
    (or all new ones, if you enable auto-push) travel over your local network
    to that Mac, encrypted with a key derived from the pairing token. Nothing
    goes to the internet. See [docs/sync.md](docs/sync.md).
  - **Vocabulary / people URL sync** — when you point the app at a vocabulary
    or people-roster file URL, it fetches them (https only, no cross-host
    redirects) when opened.
- Export is explicit: you choose what leaves the device, and when.

## License

MIT. Depends on [speech-swift](https://github.com/soniqo/speech-swift)
(Apache 2.0) and the
[MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) (MIT);
model weights carry their own licenses (Pyannote segmentation: MIT;
WeSpeaker: Apache 2.0; Parakeet: CC-BY-4.0).
