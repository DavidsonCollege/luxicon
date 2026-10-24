# Cohere Transcribe engine + speech-swift upgrade: design

**Goal:** offer Cohere Transcribe 03-2026 as an opt-in, Mac-only transcription
engine, without changing how speakers are separated on either platform. In
parallel, make the upgraded library's new diarization available behind a
switch, so it can be validated before anyone adopts it.

## Why
- **What JD asked for:** "Can we do one and two?" (2026-10-23).
  - Option 1: ship Cohere on the Mac and keep today's speaker detection.
  - Option 2: validate the new speaker detection (threshold 0.6) everywhere
    before switching.
- **Evidence from the spike** (branch `spike/cohere-asr`, report in the session
  scratchpad), on two real 28–41-minute meetings:
  - Cohere recognized the most vocabulary terms before correction.
  - It disagreed least with an independent Whisper reference: 10.5–16.2%,
    against 13.5–21.7% for Apple and Parakeet.
  - It runs as fast as Parakeet.
  - It needs about 3.6–3.9 GB of memory, so it is Mac only.
- **Why the upgrade is the risky part:** Cohere needs speech-swift v0.0.28. That
  release silently changed pyannote diarization:
  - windows overlap 90% instead of 50%;
  - per-frame speaker activity is the hard argmax, not soft probabilities;
  - clustering is global centroid linkage, not constrained agglomerative.

  At its default threshold, one meeting collapsed to a single speaker. The new
  pipeline is also about 2.5× slower. `DiarizationConfig` exposes only
  onset/offset, minimum durations and `clusteringThreshold`, so the old
  behavior can't be selected by configuration.

## Decided
1. **Upgrade** speech-swift to tag `v0.0.28` (commit `231f8eb`). The spike
   showed it needs zero code changes, and all 174 tests pass.
2. **Keep today's diarization as the default on both platforms.** Vendor the
   old pyannote pipeline from speech-swift revision `e403d0b` into LuxiconKit as
   `ClassicDiarizationPipeline`:
   - 50% window overlap
   - soft powerset probabilities
   - constrained agglomerative clustering
   - the same segmentation and WeSpeaker models, loaded through the upgraded
     library's model types

   Apache-2.0 permits this: keep the license header, add an attribution to
   `THIRD-PARTY-NOTICES.md` via `scripts/generate-notices.sh` (or by hand if the
   script doesn't cover vendored code), and add a comment naming the source
   commit. Production transcripts must come out the same as today's.
3. **Diarization method switch.** Add
   `enum DiarizationMethod { case classic, case pyannoteV2(threshold: Float) }`.
   - Default: `.classic` everywhere.
   - `.pyannoteV2` uses the library's new pipeline with `clusteringThreshold`;
     the default threshold for that case is **0.4**. See "Validation results" below; 0.6 collapsed a real meeting.
   - Not exposed in normal UI. Reachable through a luxicon-cli flag
     (`--diarizer classic|v2`, `--cluster-threshold`), and on the Mac through a
     hidden `UserDefaults` key, `diarizationMethod`, for dogfooding.
   - Flipping the default is a later decision for JD, after validation, which
     includes iPhone speed and memory.
4. **Cohere engine.**
   - Add `ASREngine.cohere`. `CohereTurnTranscriber` wraps
     `CohereTranscribeModel` with the default INT5 variant and language "en",
     and conforms to `TurnTranscriber`.
   - Link `CohereTranscribeASR` on macOS only (an SPM platform condition), with
     all code behind `#if os(macOS)`.
   - Tolerant decode: an `asrEngineChoice` of `cohere` read on iOS resolves to
     the automatic default. It can't be chosen there, but this guards against
     shared or edited state.
5. **Mac UI.**
   - Settings → Transcription picker gets a third option: "Cohere Transcribe —
     best quality (Mac only)".
   - Choosing it shows a one-line note: "Downloads a 1.6 GB model the first time
     it's used and needs about 4 GB of memory while transcribing."
   - The download happens on first use, with progress through the existing
     `ensureLoaded` stage text ("Downloading Cohere model… NN%").
   - The automatic default is unchanged (see settled call 3). Live captions
     are unchanged (streaming Parakeet EOU).
6. **Short-turn guard (Cohere only).**
   - For turns under 1.0 s, if Cohere returns one of a small set of stock
     closers ("Thank you.", "Thanks.", "Bye."), keep it only when another
     signal agrees. Otherwise fall back to Parakeet for that turn. If that's
     too complex, drop turns under 0.5 s.
   - This addresses the one hallucination seen in the spike. My call: the
     builder may pick the simplest guard that removes that case without
     emptying real short answers ("Yeah.", "Okay.").
7. **CLI.** Port the spike's useful flags to main:
   - `--engine cohere`
   - `--diarize-only`
   - `--save-diarization` / `--load-diarization`
   - `--cluster-threshold`
   - `--diarizer`

   These support future A/B work.

## Calls settled after the builder check (2026-10-23, controller)

These are my calls; JD can override any of them.

1. **What gets vendored.** In v0.0.28, `SegmentationModel`, `DiarizationHelpers`,
   `PowersetDecoder` and the pipeline initializer are internal to SpeechVAD.
   - **Vendor:** the classic pipeline plus whatever internal pieces it needs
     (segmentation model with SincNet, BiLSTM and weight loading; the
     constrained-agglomerative helpers; soft powerset decoding). Copy them from
     revision `e403d0b` into `Sources/LuxiconKit/ClassicDiarization/`. Prefix or
     namespace the types so they can't collide with SpeechVAD's.
   - **Don't fork:** no fork or patched local copy of speech-swift. A fork is a
     second repo to maintain.
   - **Same models:** the same weights from the same Hugging Face repos
     (`aufklarer/Pyannote-Segmentation-MLX`, `aufklarer/WeSpeaker-ResNet34-LM-MLX`).
     Use the public `WeSpeakerModel` where it's public.
   - **License:** add the Apache-2.0 headers and an attribution section to
     `THIRD-PARTY-NOTICES.md`.
2. **Meaning of "same transcript out."**
   - **Diarization:** must match today's, with frame agreement ≥ 99.5% and the
     same speaker counts.
   - **Parakeet:** text may change only where upstream fixed a bug. Known case:
     digit tokens used to be dropped and are now kept.
   - **Before/after check:** capture a baseline before the bump (a `main`
     worktree at `e403d0b`, in scratch) and compare Parakeet's per-turn text on
     the Meeting A and Meeting B recordings. Every difference must be explained. Same
     comparison for streaming EOU captions on a 2-minute excerpt.
   - **iPhone:** the gate is the iOS Release build plus JD's device checklist.
     There is no app test bundle.
3. **Defaults don't change.** The Settings picker keeps its current entries
   (Automatic, Apple, Luxicon/Parakeet) and gains "Cohere Transcribe — best
   quality (Mac only)". Automatic still resolves to Apple Speech on macOS 26+
   and Parakeet below. Read decision 5 above with "the automatic default stays
   the default".
4. **Enum shape.** `ASREngine.cohere` exists on all platforms, because the enum
   is shared Codable state.
   - Engine resolution treats `.cohere` as unavailable on iOS, so a persisted
     `cohere` choice on iOS resolves to `resolvedDefault()`.
   - Any engine-picker UI on iOS never lists it.
   - The existing unknown-value fallback stays as it is.
5. **Short-turn guard.** Don't load a second ASR model. For turns under 1.0 s,
   if Cohere's output is exactly a stock closer ("Thank you.", "Thanks.",
   "Thank you very much.", "Bye."), treat the turn as empty.
   - Keep the guard list small and in LuxiconKit, with tests.
   - The method switch applies to luxicon-cli and the Mac app only. The MCP
     server and listener never diarize.
6. **Recordings and baseline.** Use `<Meeting A recording, local only>`
   and `<Meeting B recording, local only>` (read-only). Build the
   baseline in a scratch worktree of `main`; never switch branches in the main
   checkout.

## Validation results (2026-10-23, 4 two-person meetings: 28–50 min)

| Meeting | v2 at 0.715 | v2 at 0.6 | v2 at 0.4 |
|---|---|---|---|
| Meeting A | collapsed to 1 speaker | 99.8% | 99.8% |
| Meeting B | 99.5% | 99.5% | 99.7% |
| Untitled | 99.6% | 99.6% | 99.6% |
| New Recording 3 | collapsed | **collapsed (59.1%)** | 96.6% |

- **Safe range:** thresholds 0.30–0.55 give the same two-speaker split on all
  four. New Recording 3 collapses at 0.575 and above, so 0.6 is NOT safe and
  the v2 default here is 0.4.
- **Where the two disagree:** of the 12 largest spans, v2 looked right in 7,
  classic in 2; the rest were split or unclear.
- **Cost:** v2 diarization is 5–6× slower on the Mac (about 0.03× real-time
  vs 0.005×); peak memory is about the same. iPhone figures are still pending.
- **If v2 ever becomes the default:** add a 1-on-1 guard. Re-cluster at a lower
  threshold, or force 2 clusters, when the second speaker has under about 5% of
  talk time. Out of scope here; the switch stays off.

## Non-goals
- Cohere on iPhone.
- Changing the default engine on either platform.
- Switching anyone to the new diarization.
- Non-English language selection UI. Cohere's language stays "en"; a picker
  can come later.
- Fixing upstream's doc comment ("Lower = more merges", which is backwards).
  Note it in code only.

## Anti-goals
- Any change to what the iPhone app produces today: diarization, ASR output, or
  speed. Same audio in, same transcript out.
- Downloading Cohere's model without the user choosing Cohere.
- A new network host. The model comes from Hugging Face, the same host as
  today's models. The privacy copy needs only a mention of the optional larger
  download.

## Verification the builder must show
- `swift test` passes, including new offline Kit tests:
  - `ASREngine` tolerant decode;
  - `DiarizationMethod` default is `.classic`;
  - if feasible offline, `ClassicDiarizationPipeline` produces the same
    clustering result as the old library on a synthetic embedding fixture.
- **Equivalence on real audio.** On the Meeting A and Meeting B recordings (Desktop,
  read-only), the classic vendored pipeline must give the same speaker segments
  as `main` today. The bar is at least 99.5% frame agreement with identical
  speaker counts; record any tiny differences and their cause.
- Mac (Developer ID) and iOS builds succeed. A Cohere transcription of one
  recording through the Mac app path, scratch store only, reaches `.ready`.
- The iPhone measurement of `.pyannoteV2` stays on JD's checklist (it needs a
  device).

## Left to the builder
- Where exactly the vendored files live and how they bind to the upgraded model
  types.
- Wording polish for the Settings note.
- The exact short-turn guard, within decision 6.
