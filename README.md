# Luxicon

**On-device 1-on-1 recorder for managers.** Record a sit-down with a direct
report on your iPhone, get a speaker-labeled transcript that never leaves the
device, and export it as clean markdown or JSON for the AI assistant of your
choice — performance summaries, check-in prep, longitudinal review.

No cloud APIs. No per-minute pricing. No audio leaving the phone.

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

Models (~700 MB) download from Hugging Face on first transcription and are
cached on-device.

Measured on an M-series Mac (release build): a 50-second two-speaker meeting
diarizes, transcribes, and speaker-matches in 4.6 s (0.09× real-time), with
every turn correctly attributed. iPhones with recent A-series chips should
land within a few multiples of that.

## Structure

```
Sources/LuxiconKit/     Core pipeline (platform-neutral Swift package)
  MeetingPipeline.swift   diarize → per-turn ASR → speaker naming
  Models.swift            transcript, turns, stats, enrollment types
  Export.swift            markdown + JSON export
Sources/LuxiconCLI/     macOS command-line harness
App/                    iOS app (SwiftUI, generated with xcodegen)
```

## Building

### iOS app

Requires Xcode 16+, iOS 18+ device (A13 or later recommended).

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
  container on-device, nowhere else.
- The only network traffic is the one-time model download from Hugging Face.
- Export is explicit: nothing leaves the device until you share a transcript.

## License

MIT. Depends on [speech-swift](https://github.com/soniqo/speech-swift)
(Apache 2.0); model weights carry their own licenses (Pyannote segmentation:
MIT; WeSpeaker: Apache 2.0; Parakeet: CC-BY-4.0).
