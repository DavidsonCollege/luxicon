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

- **`supportsContext = true`.** Vocabulary is supplied to the analyzer via
  `AnalysisContext.contextualStrings` as individual terms. The `TurnTranscriber`
  context parameter changes from prose `String?` to `[String]?` (terms):
  the only prose consumer was Qwen3-ASR, retired on main 2026-07-14
  (`2552916`), so `VocabularyCorrector.contextTerms(for:) -> [String]`
  **replaces** `contextString(for:)`. Post-ASR near-miss correction in
  `MeetingPipeline.process` still runs, as it does for every engine.
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
- **Support gating is two-stage:** the cheap sync gate is the OS version alone
  (`#available`, via `ASREngine.resolvedDefault()`), because the locale check
  (`supportedLocale(equivalentTo:)`) is async. Locale and asset failures
  surface as thrown errors at load time and are handled by the app-level
  fallback.

### `ASREngine` (existing, `MeetingPipeline.swift`)

New case `appleSpeech`. `MeetingPipeline.load(engine:)` gains the branch and
**throws** on failure (an explicit request for an unavailable engine is an
error — this keeps the CLI strict). The **fallback to `.parakeet` lives in the
app's `PipelineService.ensureLoaded`**, so processing is never blocked by the
new path; it emits a progress-stage message naming the fallback.

A static helper `ASREngine.resolvedDefault()` returns `.appleSpeech` when the
OS supports it (`#available` gate only — see above), else `.parakeet`.

### App (`App/Sources/`)

- **Updated during planning (main moved):** the experimental Qwen3 engine, its
  settings picker, and the `qwen3` enum case were retired on main 2026-07-14
  (`2552916`), which also gave `ASREngine` a tolerant decoder (unknown raw
  values decode to `.parakeet` instead of failing the whole store). Any
  previously persisted engine value therefore now reads as `.parakeet`, and no
  explicit-choice history survives — existing users can be auto-upgraded
  safely via the new choice key below.
- `Store` replaces the stored `asrEngine` with `asrEngineChoice: ASREngine?`
  where `nil` means *automatic* (resolve via `ASREngine.resolvedDefault()` at
  use time) and non-nil is an explicit user choice from the new picker. A
  computed `asrEngine` keeps call sites (`SessionProcessing`) unchanged.
- Persistence: new optional key `asrEngineChoice` in `Persisted`; the legacy
  `asrEngine` key is ignored on read (post-retirement it can only decode to
  `.parakeet`) and no longer written. Older builds ignore the unknown
  `asrEngineChoice` key and see a missing `asrEngine` key, decoding to
  `.parakeet` — downgrades are safe even when the choice is `appleSpeech`, and
  the tolerant `ASREngine` decoder adds a second layer of safety.
- A new "Transcription" section in the settings screen (`MyVoiceView`), shown
  only on iOS 26+, offers Automatic (recommended) / Apple / Luxicon (Parakeet).
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

The engine choice moves to a *new* optional key (`asrEngineChoice`), and the
legacy `asrEngine` key is no longer written. Older builds ignore unknown keys
and decode a missing `asrEngine` as `.parakeet`, so a store.json written by the
new build — including one with `"appleSpeech"` selected — decodes cleanly on
older builds. This is strictly safer than reusing the legacy key, whose decoder
would throw on an unknown raw value and trip the corrupt-store set-aside path.

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
- Removing Parakeet — it remains for iOS 18–25 devices and as fallback.
  (Qwen3 was retired separately on main, 2026-07-14.)
- DictationTranscriber, SpeechDetector, or custom language models
  (`SFCustomLanguageModelData`).

## Open questions (resolve during implementation)

1. Can one `SpeechAnalyzer` be finalized and fed again per turn, or does each
   turn need a fresh analyzer over the shared module? Verify on-device; either
   is acceptable for correctness.
2. Whether `AnalysisContext.contextualStrings` measurably biases short per-turn
   clips — if not, `supportsContext` stays true (harmless) but the near-miss
   corrector remains the effective vocabulary mechanism.
