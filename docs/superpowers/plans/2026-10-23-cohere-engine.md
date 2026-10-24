# Cohere Transcribe Engine + speech-swift Upgrade: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Upgrade speech-swift to v0.0.28 without changing speaker diarization, add Cohere Transcribe as an opt-in Mac-only engine, and put the library's new diarization behind an off-by-default switch.

**Architecture:**
- **Classic diarization stays the default.** Today's pyannote pipeline is vendored into LuxiconKit as `ClassicDiarizationPipeline`, *before* the bump, and proven identical on real audio. Then the library is bumped.
- **One diarizer seam.** A `SpeakerDiarizer` protocol lets `MeetingPipeline` run either the classic pipeline or the library's v2 pipeline, picked by `DiarizationMethod`.
- **Cohere is another `TurnTranscriber`.** It is linked on macOS only, gated by a short-turn hallucination guard, and offered only in the Mac Settings picker.

**Tech Stack:** Swift 6, speech-swift v0.0.28 (MLX), swift-testing, xcodegen/xcodebuild.

**Spec:** `docs/superpowers/specs/2026-10-23-cohere-engine-design.md` (approved by JD, including its "Calls settled" and "Validation results" sections)

## Global Constraints

- speech-swift tag `v0.0.28` (commit `231f8eb9f0971fee335fef49f42d2975e4fbf8bc`). Today's pin is revision `e403d0bdd5e134ddbca076ca9e75fd28761e69b1`.
- **Default diarization stays classic on both platforms.** It must match today's segments with frame agreement ≥ 99.5% and identical speaker counts on the Meeting A and Meeting B recordings.
- **Parakeet text changes after the bump are allowed only when an upstream fix explains them** (known case: digit tokens are no longer dropped). Every difference gets explained.
- `DiarizationMethod` defaults to `.classic`. The `.pyannoteV2` default threshold is `0.4`.
- `CohereTranscribeASR` is linked for macOS only, through an SPM platform condition. All Cohere code is behind `#if os(macOS)`.
- `ASREngine.cohere` exists on all platforms. On iOS it is unavailable and resolves to `ASREngine.resolvedDefault()`.
- **Defaults don't change.** The Settings picker is Automatic / Apple / Luxicon / "Cohere Transcribe — best quality (Mac only)". Automatic still resolves to Apple Speech on macOS 26+.
- Cohere copy when selected: "Downloads a 1.6 GB model the first time it's used and needs about 4 GB of memory while transcribing."
- **Short-turn guard:** for turns shorter than 1.0 s, Cohere output exactly equal to "Thank you.", "Thanks.", "Thank you very much." or "Bye." becomes empty.
- **Licensing:**
  - Vendored files keep their Apache-2.0 headers and get a source-commit comment.
  - Attribution goes into `THIRD-PARTY-NOTICES.md`.
  - The Cohere model is added to `scripts/model-acknowledgements.json` (Apache-2.0, `https://huggingface.co/CohereLabs/cohere-transcribe-03-2026`).
- **Privacy:** no new network host. Model downloads come from Hugging Face only. The Cohere model downloads only after the user chooses Cohere.
- **Test recordings are read-only:** `<Meeting A recording, local only>` and `<Meeting B recording, local only>`. Write all comparison artifacts to the scratch directory below and never commit them, because they hold private meeting content.
- **Scratch:** `/private/tmp/claude-502/-Users-jdmills-Documents-GitHub-luxicon/2620859b-96e2-409f-ae9f-c2b22d098484/scratchpad/cohere-build/`
- Never write to `~/Luxicon` or `~/Library/Application Support/Luxicon`. Never touch `/Applications/Luxicon.app` or the running listener.
- **Builds:** add `-skipPackagePluginValidation -skipMacroValidation` to every xcodebuild call. iOS builds use `CODE_SIGNING_ALLOWED=NO`, because the Xcode account isn't signed in. Mac builds sign with Developer ID.
- **Reference implementation:** the spike branch `spike/cohere-asr` (commit `6fbea05`) has working code for the Cohere adapter, CLI flags and pipeline hooks. Read it with `git show 6fbea05`. Reuse it, but don't merge that branch.

## Review Focus

1. **A silent change in the iPhone transcript.** The bump must not move diarization, and any Parakeet text change must be explained. Task 3's comparison step pins this.
2. **A persisted `cohere` choice read on iOS** must resolve to the automatic default, never crash or select Parakeet by accident. Task 5's `cohereUnavailableOnIOSResolvesToDefault` test pins this.
3. **Choosing Cohere when there's no network or the disk is full during the 1.6 GB download.** The session must fail with a readable error and stay retryable, as today's model-download failures do. Task 6 exercises this with `-simulateModelDownloadFailure`.
4. **A hallucinated closer on a short turn** ("Thank you." on 0.95 s). The guard empties it, but a real "Okay." or "Yeah." must survive. Task 5's guard tests pin this.
5. **Running v2 diarization by accident.** The default must be classic everywhere. Only the CLI flag or the hidden Mac key selects v2. Task 4's `defaultIsClassic` test pins this.

---

### Task 1: CLI A/B flags and baseline capture (before any library change)

**Files:**
- Modify: `Sources/LuxiconCLI/LuxiconCLI.swift`
- Modify: `Sources/LuxiconKit/MeetingPipeline.swift`. This only adds two optional parameters: `precomputedDiarization: DiarizationResult? = nil` and `onTurn: ((TurnRecord) -> Void)? = nil`, placed after `progress`.
- Create: `Sources/LuxiconKit/TurnRecord.swift`:
  `public struct TurnRecord: Codable, Sendable { start: Double; end: Double; speakerId: Int; text: String }`

**Interfaces:**
- Produces CLI flags:
  - `--diarize-only` writes the diarization and skips ASR.
  - `--save-diarization <path>` / `--load-diarization <path>` save or load the diarization as JSON (segments, numSpeakers, speakerEmbeddings).
  - `--turn-log <path>` writes one `TurnRecord` per line as JSONL.
- Produces `public struct DiarizationFile: Codable` in `TurnRecord.swift`. It converts to and from `DiarizationResult`.
- Produces subcommand `luxicon-cli captions <audio> --seconds <n>`. It feeds the first n seconds through `LiveTranscriptionEngine` in 100 ms chunks and prints the final committed caption text.

- [ ] **Step 1:** Write the test `diarizationFileRoundTrips`. It round-trips a `DiarizationResult` with 2 segments through `DiarizationFile` and checks equal segments and speaker count.
- [ ] **Step 2:** Run `swift test --filter TurnRecordTests`. Expected: FAIL to compile.
- [ ] **Step 3:** Implement the types, the flags, the hooks and the `captions` subcommand. Port them from spike commit `6fbea05` where it applies.
- [ ] **Step 4:** Run `swift test`. Expected: all tests pass. Build the release CLI: `swift build -c release --product luxicon-cli` and `bash scripts/build_mlx_metallib.sh release`.
- [ ] **Step 5:** Capture the baseline into `<scratch>/baseline/` with the release CLI on today's library:
  - `--engine parakeet --save-diarization <scratch>/baseline/<name>.diar.json --turn-log <scratch>/baseline/<name>.parakeet.jsonl` for both recordings.
  - `captions` with `--seconds 120` on the Meeting A recording, written to `<scratch>/baseline/meeting-a.captions.txt`.
  - Expected: four non-empty files plus the caption text.
- [ ] **Step 6:** Commit with the message `CLI: diarization save/load, turn log, captions subcommand for A/B checks`. Don't commit any baseline file.

### Task 2: Vendor the classic diarization pipeline (still on the old library)

**Files:**
- Create: `Sources/LuxiconKit/ClassicDiarization/`, holding the pyannote pipeline from speech-swift `e403d0b` plus every internal piece it needs: the segmentation model (SincNet, BiLSTM, weight loading), the constrained agglomerative clustering helpers and soft powerset decoding.
  - Prefix the types with `Classic` (e.g. `ClassicDiarizationPipeline`, `ClassicSegmentationModel`) so they never collide with SpeechVAD's.
  - Keep the Apache-2.0 headers and add `// Vendored from soniqo/speech-swift @ e403d0b (Apache-2.0)`.
- Create: `Sources/LuxiconKit/SpeakerDiarizer.swift`:
  ```swift
  public protocol SpeakerDiarizer: AnyObject {
      func diarize(audio: [Float], sampleRate: Int, config: DiarizationConfig) -> DiarizationResult
      var embeddingModel: WeSpeakerModel { get }
  }
  ```
  If the library's diarize signature differs, match it.
- Modify: `MeetingPipeline.swift`.
  - `diarizer: any SpeakerDiarizer`.
  - `load(...)` builds a `ClassicDiarizationPipeline` from the same Hugging Face weights (`aufklarer/Pyannote-Segmentation-MLX`, `aufklarer/WeSpeaker-ResNet34-LM-MLX`), using the library's public loaders where they're public.
- Modify: `THIRD-PARTY-NOTICES.md` (and `App/Resources/THIRD-PARTY-NOTICES.md` via `scripts/generate-notices.sh`, or by hand). Add a "Vendored source: speech-swift (Apache-2.0)" section.
- Test: `Tests/LuxiconKitTests/ClassicDiarizationTests.swift`

**Interfaces:**
- Produces: `public final class ClassicDiarizationPipeline: SpeakerDiarizer` and `static func load(progress: (@Sendable (Double, String) -> Void)?) async throws -> ClassicDiarizationPipeline`.

- [ ] **Step 1:** Write `classicClusteringSeparatesTwoSyntheticSpeakers`. Feed the vendored clustering helper 40 synthetic 256-dimensional embeddings around two orthogonal centroids (cosine noise 0.05), at the default threshold. Expect exactly 2 clusters, each with all members of one group. This test runs offline with no models.
- [ ] **Step 2:** Run `swift test --filter ClassicDiarizationTests`. Expected: FAIL to compile.
- [ ] **Step 3:** Vendor the code and wire up `SpeakerDiarizer`.
- [ ] **Step 4:** Run `swift test`. Expected: PASS.
- [ ] **Step 5:** Check equivalence on today's library.
  - Run the release CLI with `--diarize-only --save-diarization <scratch>/t2/<name>.diar.json` on both recordings.
  - Compare to `<scratch>/baseline/` with a small comparison script in scratch.
  - Expected: frame agreement ≥ 99.9%, the same speaker count, and diarization time within 10% of the baseline. It is the same code on the same library.
- [ ] **Step 6:** Commit with the message `Kit: vendor classic pyannote diarization behind a SpeakerDiarizer seam`.

### Task 3: Bump speech-swift to v0.0.28, with classic diarization unchanged

**Files:**
- Modify: `Package.swift`: revision `231f8eb9f0971fee335fef49f42d2975e4fbf8bc`. Commit `Package.resolved` too.
- Modify: `Sources/LuxiconKit/ClassicDiarization/*`. Rebind it to the upgraded library's public types. Vendor further pieces only if the bump made them internal.

- [ ] **Step 1:** Bump the version. Run `swift build -c release --product luxicon-cli`, `bash scripts/build_mlx_metallib.sh release` and `swift test`. Expected: the build succeeds and every test passes.
- [ ] **Step 2:** Compare with the baseline on both recordings.
  - **Diarization:** `--diarize-only`. Frame agreement must be ≥ 99.5% with the same speaker counts.
  - **Parakeet:** `--load-diarization <baseline diar>` with `--turn-log`. Diff every turn's text against the baseline. Every difference must be explained (e.g. digits that are now kept). Write the categorized list to `<scratch>/t3/parakeet-diff.md`.
  - **Captions:** run `captions --seconds 120`, diff against the baseline captions, and explain the differences.
  - **Speed:** diarization time within 15% of the baseline.
- [ ] **Step 3:** Build the Mac app (Debug, Developer ID) and the iOS app (`CODE_SIGNING_ALLOWED=NO`). Expected: both report `** BUILD SUCCEEDED **`.
- [ ] **Step 4:** Commit with the message `Deps: speech-swift v0.0.28; classic diarization unchanged`.

### Task 4: DiarizationMethod switch

**Files:**
- Create: `Sources/LuxiconKit/DiarizationMethod.swift`:
  ```swift
  public enum DiarizationMethod: Codable, Sendable, Equatable {
      case classic
      case pyannoteV2(threshold: Float)
      public static let `default`: DiarizationMethod = .classic
      public static let v2DefaultThreshold: Float = 0.4
      public init?(cliValue: String, threshold: Float?)   // "classic" | "v2"
  }
  ```
- Modify: `MeetingPipeline.load(engine:diarization:progress:)` to take `diarization: DiarizationMethod = .default`. `.pyannoteV2` loads the library's `DiarizationPipeline` and passes `clusteringThreshold` through `Options.diarization`. Add a code comment that upstream's "lower = more merges" comment is backwards.
- Modify: the CLI to take `--diarizer classic|v2` and `--cluster-threshold <f>`.
- Modify: `App/Sources/PipelineService.swift`. On macOS, read the hidden `UserDefaults` key `diarizationMethod` (`"classic"` or `"v2"`, optional `diarizationThreshold`). iOS always uses `.default`. Reload the cached pipeline when the method changes.
- Test: `Tests/LuxiconKitTests/DiarizationMethodTests.swift`

- [ ] **Step 1:** Write the tests:
  - `defaultIsClassic`: `DiarizationMethod.default == .classic`.
  - `v2DefaultThresholdIsPoint4`: `DiarizationMethod.v2DefaultThreshold == 0.4`.
  - `cliParsing`: `"v2"` with nil gives `.pyannoteV2(threshold: 0.4)`, `"v2"` with 0.5 gives 0.5, `"classic"` gives `.classic`, and `"x"` gives nil.
- [ ] **Step 2:** Run the tests. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `swift test`. Expected: PASS. Then run the CLI with `--diarizer v2 --diarize-only` on the Meeting A recording. Expected: 2 speakers, and agreement with classic ≥ 99% (the validation measured 99.8%).
- [ ] **Step 5:** Build Mac and iOS. Commit with the message `Kit: DiarizationMethod switch (classic default, v2 opt-in at 0.4)`.

### Task 5: Cohere engine in LuxiconKit

**Files:**
- Modify: `Package.swift`. Add `.product(name: "CohereTranscribeASR", package: "speech-swift", condition: .when(platforms: [.macOS]))` to LuxiconKit.
- Create: `Sources/LuxiconKit/CohereTurnTranscriber.swift`, entirely under `#if os(macOS)`:
  - `final class CohereTurnTranscriber: TurnTranscriber`
  - `static func load(progress:) async throws -> CohereTurnTranscriber` (INT5 default, language `"en"`)
  - Port it from spike `6fbea05`.
- Create: `Sources/LuxiconKit/ShortTurnGuard.swift` (all platforms, pure):
  - `public enum ShortTurnGuard { static let maxDuration = 1.0; static let stockClosers: Set<String> = ["Thank you.", "Thanks.", "Thank you very much.", "Bye."] }`
  - `public static func filter(_ text: String, duration: Double) -> String`
- Modify: `MeetingPipeline.swift`.
  - Add `ASREngine.cohere` (raw value `"cohere"`).
  - Add `public var isAvailable: Bool`, false on iOS.
  - `resolved(_ choice: ASREngine?) -> ASREngine` returns `resolvedDefault()` when the choice is nil or unavailable.
  - `load` handles `.cohere`. Apply `ShortTurnGuard` to Cohere turns only.
- Modify: the CLI so `--engine cohere` works.
- Modify: `scripts/model-acknowledgements.json` (add Cohere Transcribe 03-2026, Apache-2.0, © Cohere, MLX conversion by the speech-swift project). Regenerate `App/Resources/acknowledgements.json` with `scripts/generate-notices.sh`.
- Test: `Tests/LuxiconKitTests/CohereEngineTests.swift`

- [ ] **Step 1:** Write the tests:
  - `guardEmptiesStockCloserOnShortTurn`: `filter("Thank you.", duration: 0.95) == ""`.
  - `guardKeepsRealShortAnswers`: `filter("Okay.", duration: 0.6) == "Okay."` and `filter("Yeah.", 0.4) == "Yeah."`.
  - `guardKeepsClosersOnLongTurns`: `filter("Thank you.", duration: 1.2) == "Thank you."`.
  - `cohereRawValueRoundTrips`: encode and decode `.cohere`.
  - `cohereUnavailableOnIOSResolvesToDefault`: on iOS, `ASREngine.resolved(.cohere) == ASREngine.resolvedDefault()`. On macOS the same call returns `.cohere`. Use `#if` branches in the test, because the Mac host runs the macOS branch.
- [ ] **Step 2:** Run the tests. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `swift test`. Expected: PASS. Then run the CLI with `--engine cohere --load-diarization <baseline meeting-a>`. Expected: it completes, with peak RSS ≤ 4.5 GB (`/usr/bin/time -l`) and no "Thank you." on any turn under 1.0 s.
- [ ] **Step 5:** Build Mac and iOS. On iOS, confirm the binary doesn't link CohereTranscribeASR: `nm` on the app binary shows no `CohereTranscribe` symbols. Commit with the message `Kit: Cohere Transcribe engine (macOS) with short-turn guard`.

### Task 6: Mac Settings option, download UX and docs

**Files:**
- Modify: `App/Sources/Views/MyVoiceView.swift`, the Transcription section. On macOS add `Text("Cohere Transcribe — best quality (Mac only)").tag(ASREngine?.some(.cohere))`. When `.cohere` is selected, show the Global Constraints copy as the footer line. iOS stays unchanged.
- Modify: `App/Sources/PipelineService.swift` and `App/Sources/Store.swift`. Engine resolution goes through `ASREngine.resolved(_:)`. Download progress shows "Downloading Cohere model… NN%" through the existing stage text.
- Modify: `App/MacSources/DebugLaunchOptions.swift`. Add DEBUG-only `-asrEngine <raw>` and `-simulateModelDownloadFailure`.
- Modify: `README.md` (Mac section and privacy). Add one line: "Optional: Cohere Transcribe (Mac only) downloads a 1.6 GB model from Hugging Face when you choose it." Also `docs/privacy-policy.md` with the same fact.

- [ ] **Step 1:** Build the Mac Debug app. Run it against a scratch store and library with `-seedSessionFromWAV <Meeting A recording converted to a 16 kHz WAV in scratch> "Test Person" -asrEngine cohere`. Expected: the session reaches `.ready`, its transcript has 2 speakers, and the log shows the Cohere engine.
- [ ] **Step 2:** Run the same with `-simulateModelDownloadFailure`. Expected: the session goes `.failed` with a readable message, and Retry works once the flag is removed.
- [ ] **Step 3:** Screenshot Settings with Cohere selected (Screen Recording is granted) and check the copy.
- [ ] **Step 4:** Build iOS. Expected: success, and the picker is unchanged. The `#if os(macOS)` gate is visible in the diff.
- [ ] **Step 5:** Commit with the message `Mac: Cohere Transcribe option in Settings; docs`.
