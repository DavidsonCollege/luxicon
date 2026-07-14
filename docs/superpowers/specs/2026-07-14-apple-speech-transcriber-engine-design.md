# Apple SpeechTranscriber ASR engine (iOS 26+)

**Date:** 2026-07-14
**Status:** Approved design, pending implementation plan

## Goal

Add Apple's on-device `SpeechTranscriber` (Speech framework, iOS 26+ / macOS 26+)
as a third ASR engine for the batch `MeetingPipeline`, and make it the default on
devices that support it. Diarization is unchanged — SpeechTranscriber does no
speaker diarization (true in iOS 26 and still true in iOS 27); the MLX/pyannote
diarizer remains the front half of the pipeline.

Motivations, in priority order: transcription quality (Apple's long-form model
benchmarks ahead of Whisper-class models), memory/stability (the model runs
out-of-process, so it is immune to the MLX cache growth and CoreML autorelease/E5
failure modes that required the last three stability commits), footprint (system
asset — no per-app model download), and eventually live captions (explicitly out
of scope here; see Non-goals).

## Approach

Per-turn engine behind the existing `TurnTranscriber` seam (Approach A from
brainstorming). Each diarized turn's audio slice is transcribed independently,
exactly as Parakeet and Qwen3 do today. A whole-file pass with timestamp
alignment (Approach B) was rejected: it adds a second code path through
`process`, and it cannot attribute overlapping speech correctly — per-turn
slicing transcribes each speaker's overlap region from that speaker's own audio.

## Components

### `AppleSpeechTranscriber` (new, `Sources/LuxiconKit/AppleSpeechTranscriber.swift`)

`@available(iOS 26, macOS 26, *) public final class AppleSpeechTranscriber: TurnTranscriber`

- **`supportsContext = true`.** The vocabulary context string is supplied to the
  analyzer via `AnalysisContext.contextualStrings` (as individual terms, not the
  joined prose string — `VocabularyCorrector` gains a
  `contextTerms(for:) -> [String]` alongside `contextString(for:)` if needed).
  Post-ASR near-miss correction in `MeetingPipeline.process` still runs, as it
  does for every engine.
- **`transcribeTurn(_:sampleRate:context:)`** bridges sync→async with a
  semaphore: convert `[Float]` @ 16 kHz to an `AVAudioPCMBuffer` (in the format
  from `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)`), wrap in
  `AnalyzerInput`, run `analyzer.analyzeSequence(_:)` over a single-element
  input sequence, `finalizeAndFinishThroughEndOfInput()` (or per-turn finalize —
  see Open questions), and concatenate the `results` texts. `process` already
  runs on a background task, so blocking is acceptable and matches the existing
  synchronous contract.
- **Module lifecycle:** one `SpeechTranscriber(locale:preset:)` module created at
  load using `SpeechTranscriber.supportedLocale(equivalentTo: .current)`.
  Analyzer reuse across turns is an open question verified on-device; the
  fallback of one `SpeechAnalyzer` per turn is acceptable because the module and
  assets stay loaded.
- **`static func load(progress:) async throws`** — checks locale support,
  requests the model asset via
  `AssetInventory.assetInstallationRequest(supporting:)` →
  `downloadAndInstall()` (reporting progress through the same
  `(Double, String)` handler the other engines use), and throws
  `AppleSpeechError.unavailable(reason:)` if the OS, locale, or asset can't
  satisfy the request.
- **`static var isSupported: Bool`** — cheap runtime gate (OS version + locale
  in `supportedLocales`) usable from the app without loading anything.

### `ASREngine` (existing, `MeetingPipeline.swift`)

New case `appleSpeech`. `MeetingPipeline.load(engine:)` gains the branch; on
`AppleSpeechError` it **falls back to `.parakeet`** rather than failing the
meeting — processing must never be blocked by the new path. The pipeline
resolution reports which engine actually loaded so the UI can show it.

A static helper `ASREngine.resolvedDefault` returns `.appleSpeech` when
`AppleSpeechTranscriber.isSupported`, else `.parakeet`.

### App (`App/Sources/`)

- `Store.asrEngine`'s property initializer and `load()`'s decode fallback both
  change from `.parakeet` to `ASREngine.resolvedDefault`, so new installs (and
  pre-field stores) default to Apple on supported devices. **Limitation:** the
  app persists `asrEngine` unconditionally on every save, so existing installs
  all have `"parakeet"` on disk regardless of whether the user ever touched the
  picker — a persisted value is indistinguishable from an explicit choice and is
  preserved. Existing users get the new engine by selecting it in settings; we
  do not migrate them automatically.
- The engine picker in settings shows "Apple (system)" only when
  `AppleSpeechTranscriber.isSupported`.
- `PipelineService` passes the engine through unchanged; if the pipeline fell
  back at load time, surface the actually-loaded engine in the processing UI
  string (no new persisted state).

### CLI (`Sources/LuxiconCLI/`)

`--engine appleSpeech` works for free once the case exists (the CLI parses
`ASREngine(rawValue:)`). This is the primary verification path on macOS 26,
consistent with how summarizer changes are verified via `luxicon-cli`.

## Data flow (unchanged)

diarize → capSpeakers → buildTurns → per-turn `transcribeBounded` (60 s
chunking and autoreleasepool draining still apply — harmless for an
out-of-process engine) → vocabulary near-miss correction → enrollment naming.

## Error handling

- Load-time failure (unsupported locale, asset install failure, OS too old):
  typed `AppleSpeechError`; app falls back to Parakeet and logs; CLI prints the
  reason and exits nonzero (explicit flag = explicit failure).
- Per-turn analysis error: return empty `TranscriptionResult`; `process` already
  skips empty turns. No retry logic in v1.
- Cancellation: unchanged — checked between turns in `process`.

## Persistence back-compat

`Persisted.asrEngine` is already `ASREngine?` with a `?? .parakeet` fallback, so
current builds are unaffected. A store.json containing `"appleSpeech"` decoded
by an *older* build would throw during `Persisted` decode and trip the
corrupt-store set-aside path. This is the same exposure `SummaryEngine` cases
already have, downgrade installs are not a supported path, and the set-aside is
non-destructive — accepted, not mitigated, in v1.

## Testing & verification

- Unit tests (offline, LuxiconKit only): `ASREngine.resolvedDefault` fallback
  logic (injectable support flag), Float→PCM buffer conversion helper,
  vocabulary `contextTerms` output. No test may touch `AssetInventory` or
  trigger a model download.
- Manual verification: `luxicon-cli transcribe --engine appleSpeech` on macOS 26
  against a known recording; compare against Parakeet output. Then a real
  on-device meeting (Release build) checking quality, memory high-water mark,
  and that a long meeting survives without jetsam.

## Non-goals

- Live captions via SpeechAnalyzer volatile results (follow-up spec; keeps
  Parakeet streaming for now).
- Whole-file transcription with timestamp alignment.
- Removing Parakeet/Qwen3 — they remain for iOS 18–25 devices and as fallback.
- DictationTranscriber, SpeechDetector, or custom language models
  (`SFCustomLanguageModelData`).

## Open questions (resolve during implementation)

1. Can one `SpeechAnalyzer` be finalized and fed again per turn, or does each
   turn need a fresh analyzer over the shared module? Verify on-device; either
   is acceptable for correctness.
2. Whether `AnalysisContext.contextualStrings` measurably biases short per-turn
   clips — if not, `supportsContext` stays true (harmless) but the near-miss
   corrector remains the effective vocabulary mechanism.
