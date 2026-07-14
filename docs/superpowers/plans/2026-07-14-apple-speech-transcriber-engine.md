# Apple SpeechTranscriber ASR Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Apple's on-device `SpeechTranscriber` (Speech framework, iOS 26+/macOS 26+) as a third ASR engine behind the existing `TurnTranscriber` seam, defaulting to it automatically on supported devices with silent fallback to Parakeet.

**Architecture:** Diarization is untouched. A new `AppleSpeechTranscriber` class conforms to `TurnTranscriber`, bridging the async SpeechAnalyzer API to the synchronous per-turn contract. The app replaces its stored engine with an optional *choice* (`nil` = automatic), resolved at use time.

**Tech Stack:** Swift 6, Speech framework (`SpeechAnalyzer`/`SpeechTranscriber`/`AssetInventory`, iOS 26+), AVFoundation (`AVAudioPCMBuffer`), swift-testing.

**Spec:** `docs/superpowers/specs/2026-07-14-apple-speech-transcriber-engine-design.md`

## Global Constraints

- Deployment targets stay **iOS 18.0 / macOS 15.0** (`Package.swift` platforms unchanged); all new-API use gated `@available(iOS 26.0, macOS 26.0, *)` / `if #available`.
- Tests are **offline** — no test may touch `AssetInventory`, download assets, or instantiate `SpeechAnalyzer`.
- No new package dependencies.
- `Persisted` decode back-compat: never write a value an older build can't decode. The legacy `asrEngine` key is read but **never written**; the new key is `asrEngineChoice`.
- The `.xcodeproj` is generated — but no App source files are added or removed by this plan, so **no `xcodegen generate` is required**.
- SDK-name caveat: `SpeechAnalyzer`-family symbol names in Task 2 were taken from Apple's docs index (`analyzeSequence(_:)`, `finalizeAndFinishThroughEndOfInput()`, `setContext(_:)`, `AnalysisContext.contextualStrings`, `AssetInventory.assetInstallationRequest(supporting:)`, `SpeechTranscriber.supportedLocale(equivalentTo:)`, `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)`). If a signature differs when compiling against the real SDK (this Mac runs macOS 26 and `swift build` will tell you), adapt to the SDK — the *shape* of the design is what's binding, not the exact spelling.
- Commit messages follow the repo style: `Kit: …`, `App: …`, `CLI: …`, `Docs: …`.
- **Branch:** implementation happens on a feature branch off `main` (e.g. `feat/apple-speech-engine`), merged via PR like the rest of this repo's work.
- **Dirty worktree caution:** `main`'s working tree currently carries unrelated in-flight modifications (`SessionDetailView.swift`, `AppleIntelligenceChat.swift`, `Export.swift`, `MeetingSummarizer.swift`, `SummarizerTests.swift`). Never `git add -A` / `git add .` — stage only the files each task names.

---

### Task 1: Vocabulary context becomes a term list through the `TurnTranscriber` seam

The protocol passes `context: String?` — a prose biasing prompt whose only
consumer (Qwen3-ASR) was retired on main 2026-07-14 (`2552916`). Apple's
`AnalysisContext.contextualStrings` wants discrete terms. Replace prose with
terms end to end: `contextTerms(for:)` replaces `contextString(for:)`.

**Files:**
- Modify: `Sources/LuxiconKit/MeetingPipeline.swift` (protocol, Parakeet extension, `process` line ~158, `transcribeBounded`)
- Modify: `Sources/LuxiconKit/Vocabulary.swift` (replace `contextString(for:)`, update the type doc comment's item 1)
- Test: `Tests/LuxiconKitTests/VocabularyTests.swift` (replace `contextStringBuildsAndSkipsEmpty` ~line 56), `Tests/LuxiconKitTests/PipelineLogicTests.swift`

**Interfaces:**
- Produces:
  ```swift
  // protocol change (context is now vocabulary terms):
  func transcribeTurn(_ audio: [Float], sampleRate: Int, context: [String]?) -> TranscriptionResult
  // replaces contextString(for:):
  VocabularyCorrector.contextTerms(for: [VocabularyEntry]) -> [String]
  ```

- [ ] **Step 1: Write the failing test for `contextTerms`**

In `Tests/LuxiconKitTests/VocabularyTests.swift`, add to the existing suite:

```swift
@Test func contextTermsReturnsTrimmedNonEmptyTerms() {
    let entries = [
        VocabularyEntry(term: "  Kubernetes "),
        VocabularyEntry(term: ""),
        VocabularyEntry(term: "Sam Rivera"),
    ]
    #expect(VocabularyCorrector.contextTerms(for: entries) == ["Kubernetes", "Sam Rivera"])
}

@Test func contextTermsEmptyForNoEntries() {
    #expect(VocabularyCorrector.contextTerms(for: []) == [])
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter VocabularyTests`
Expected: FAIL — `contextTerms` does not exist (compile error).

- [ ] **Step 3: Implement `contextTerms`, delete `contextString`**

In `Sources/LuxiconKit/Vocabulary.swift`, replace `contextString(for:)` with:

```swift
    /// Discrete vocabulary terms for engines that bias on term lists
    /// (Apple SpeechTranscriber's contextual strings).
    public static func contextTerms(for entries: [VocabularyEntry]) -> [String] {
        entries
            .map { $0.term.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
```

Update item 1 of the `VocabularyCorrector` type doc comment to match:

```swift
/// 1. `contextTerms(for:)` — decoder-level biasing for engines that accept
///    contextual terms (Apple SpeechTranscriber).
```

Delete the now-orphaned `contextStringBuildsAndSkipsEmpty` test (~line 56 of
`VocabularyTests.swift`) — its intent is covered by the two new tests.

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter VocabularyTests`
Expected: PASS.

- [ ] **Step 5: Change the protocol's context parameter to terms**

In `Sources/LuxiconKit/MeetingPipeline.swift`, change the protocol method:

```swift
public protocol TurnTranscriber: AnyObject {
    /// Whether `context` is honored (decoder-level vocabulary biasing).
    var supportsContext: Bool { get }
    func transcribeTurn(_ audio: [Float], sampleRate: Int, context: [String]?) -> TranscriptionResult
}
```

Update the Parakeet conformance (the only one left):

```swift
extension ParakeetASRModel: TurnTranscriber {
    public var supportsContext: Bool { false }
    public func transcribeTurn(_ audio: [Float], sampleRate: Int, context: [String]?) -> TranscriptionResult {
        transcribeWithLanguage(audio: audio, sampleRate: sampleRate, language: nil)
    }
}
```

In `process(...)` (~line 158), replace the context line:

```swift
        let context = asr.supportsContext ? VocabularyCorrector.contextTerms(for: vocabulary) : nil
```

Update `transcribeBounded`'s signature (`context: String?` → `context: [String]?`); its body only forwards `context`, so nothing else changes.

- [ ] **Step 6: Update the test mock's signature**

In `Tests/LuxiconKitTests/PipelineLogicTests.swift` line ~164, the mock transcriber's
`transcribeTurn(_ audio:sampleRate:context: String?)` becomes `context: [String]?`.
The `transcribeBounded(..., context: nil)` call sites need no change.

- [ ] **Step 7: Run the full suite**

Run: `swift test`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/LuxiconKit/MeetingPipeline.swift Sources/LuxiconKit/Vocabulary.swift Tests/LuxiconKitTests/VocabularyTests.swift Tests/LuxiconKitTests/PipelineLogicTests.swift
git commit -m "Kit: vocabulary context through TurnTranscriber is a term list, not prose"
```

---

### Task 2: `AppleSpeechTranscriber` engine

**Files:**
- Create: `Sources/LuxiconKit/AppleSpeechTranscriber.swift`
- Test: `Tests/LuxiconKitTests/AppleSpeechTranscriberTests.swift` (buffer conversion only — offline)

**Interfaces:**
- Consumes: `TurnTranscriber` with `context: [String]?` (Task 1), `TranscriptionResult` (speech-swift).
- Produces:
  ```swift
  @available(iOS 26.0, macOS 26.0, *)
  public final class AppleSpeechTranscriber: TurnTranscriber {
      public enum LoadError: Error, LocalizedError {
          case unsupportedLocale(Locale)
          case noCompatibleAudioFormat
      }
      public static func load(progress: (@Sendable (Double, String) -> Void)?) async throws -> AppleSpeechTranscriber
      // TurnTranscriber:
      public var supportsContext: Bool { true }
      public func transcribeTurn(_ audio: [Float], sampleRate: Int, context: [String]?) -> TranscriptionResult
      // testable helper:
      static func pcmBuffer(from samples: [Float], sampleRate: Int, converting to: AVAudioFormat?) throws -> AVAudioPCMBuffer
  }
  ```

- [ ] **Step 1: Write the failing buffer-conversion tests**

Create `Tests/LuxiconKitTests/AppleSpeechTranscriberTests.swift`:

```swift
import Testing
import AVFoundation
@testable import LuxiconKit

@Suite struct AppleSpeechTranscriberTests {

    @available(iOS 26.0, macOS 26.0, *)
    @Test func pcmBufferCarriesSamplesInNativeFormat() throws {
        let samples: [Float] = [0.0, 0.5, -0.5, 1.0]
        let buffer = try AppleSpeechTranscriber.pcmBuffer(
            from: samples, sampleRate: 16000, converting: nil)
        #expect(buffer.frameLength == 4)
        #expect(buffer.format.sampleRate == 16000)
        #expect(buffer.format.channelCount == 1)
        let out = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: 4)
        #expect(Array(out) == samples)
    }

    @available(iOS 26.0, macOS 26.0, *)
    @Test func pcmBufferConvertsSampleRate() throws {
        // 1 s of signal at 16 kHz converts to ~32000 frames at 32 kHz —
        // same duration, double the frame count.
        let samples = [Float](repeating: 0.25, count: 16000)
        let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 32000, channels: 1, interleaved: false)!
        let buffer = try AppleSpeechTranscriber.pcmBuffer(
            from: samples, sampleRate: 16000, converting: target)
        #expect(buffer.format.sampleRate == 32000)
        // Allow converter edge effects: within 1% of expected 32000 frames.
        #expect(abs(Int(buffer.frameLength) - 32000) < 320)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter AppleSpeechTranscriberTests`
Expected: FAIL — type does not exist (compile error).

- [ ] **Step 3: Implement the engine**

Create `Sources/LuxiconKit/AppleSpeechTranscriber.swift`. This is the complete file; per the Global Constraints, adjust exact SpeechAnalyzer spellings to the SDK if the compiler disagrees:

```swift
import Foundation
import AVFoundation
import Speech

/// Apple's on-device long-form transcriber (Speech framework, iOS 26+).
///
/// The model is a system asset: no per-app download, and inference runs
/// out-of-process — it does not contribute to this process's memory ceiling
/// the way the CoreML/MLX engines do. Diarization still happens upstream;
/// this class only transcribes per-turn audio slices.
@available(iOS 26.0, macOS 26.0, *)
public final class AppleSpeechTranscriber: TurnTranscriber {

    public enum LoadError: Error, LocalizedError {
        case unsupportedLocale(Locale)
        case noCompatibleAudioFormat

        public var errorDescription: String? {
            switch self {
            case .unsupportedLocale(let locale):
                return "Apple speech transcription does not support the \(locale.identifier) locale on this device."
            case .noCompatibleAudioFormat:
                return "Apple speech transcription reported no compatible audio format."
            }
        }
    }

    private let locale: Locale
    private let analyzerFormat: AVAudioFormat

    private init(locale: Locale, analyzerFormat: AVAudioFormat) {
        self.locale = locale
        self.analyzerFormat = analyzerFormat
    }

    /// Resolve the locale, install the system model asset if needed, and
    /// verify an audio format. Mirrors the other engines' `fromPretrained`
    /// contract (progress in 0...1 with a stage string).
    public static func load(
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> AppleSpeechTranscriber {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            throw LoadError.unsupportedLocale(.current)
        }
        let transcriber = SpeechTranscriber(
            locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            progress?(0.1, "Downloading system speech model…")
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw LoadError.noCompatibleAudioFormat
        }
        progress?(1.0, "Speech model ready")
        return AppleSpeechTranscriber(locale: locale, analyzerFormat: format)
    }

    // MARK: - TurnTranscriber

    public var supportsContext: Bool { true }

    /// Synchronous bridge over the async SpeechAnalyzer session. `process`
    /// already runs on a background task, so blocking this thread is the
    /// same contract the CoreML/MLX engines have.
    public func transcribeTurn(
        _ audio: [Float], sampleRate: Int, context: [String]?
    ) -> TranscriptionResult {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result = TranscriptionResult(text: "")
        let work = Task { [locale, analyzerFormat] in
            defer { semaphore.signal() }
            do {
                let text = try await Self.analyze(
                    audio: audio, sampleRate: sampleRate, locale: locale,
                    format: analyzerFormat, terms: context ?? [])
                result = TranscriptionResult(text: text)
            } catch {
                // Per-turn failure → empty text; process() skips empty turns.
                result = TranscriptionResult(text: "")
            }
        }
        semaphore.wait()
        _ = work
        return result
    }

    /// One analyzer session per turn: modules are cheap once the asset is
    /// installed, and a fresh session sidesteps any finalize-then-reuse
    /// ambiguity in the analyzer lifecycle.
    private static func analyze(
        audio: [Float], sampleRate: Int, locale: Locale,
        format: AVAudioFormat, terms: [String]
    ) async throws -> String {
        let transcriber = SpeechTranscriber(
            locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !terms.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings = [.general: terms]
            try await analyzer.setContext(context)
        }

        let buffer = try pcmBuffer(from: audio, sampleRate: sampleRate, converting: format)
        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        continuation.yield(AnalyzerInput(buffer: buffer))
        continuation.finish()

        // Collect results concurrently with analysis; the sequence ends when
        // the analyzer finishes.
        async let collected: [String] = {
            var parts: [String] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                if !text.isEmpty { parts.append(text) }
            }
            return parts
        }()

        try await analyzer.analyzeSequence(inputSequence)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collected.joined(separator: " ")
    }

    // MARK: - Buffer conversion (testable, offline)

    /// Build a mono Float32 `AVAudioPCMBuffer` from raw samples, optionally
    /// converting to the analyzer's preferred format.
    static func pcmBuffer(
        from samples: [Float], sampleRate: Int, converting target: AVAudioFormat?
    ) throws -> AVAudioPCMBuffer {
        guard let nativeFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate),
            channels: 1, interleaved: false),
            let native = AVAudioPCMBuffer(
                pcmFormat: nativeFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else {
            throw LoadError.noCompatibleAudioFormat
        }
        native.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            native.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        guard let target, target != nativeFormat else { return native }

        guard let converter = AVAudioConverter(from: nativeFormat, to: target),
              let converted = AVAudioPCMBuffer(
                pcmFormat: target,
                frameCapacity: AVAudioFrameCount(
                    (Double(samples.count) * target.sampleRate / Double(sampleRate)).rounded(.up)))
        else {
            throw LoadError.noCompatibleAudioFormat
        }
        var fed = false
        var conversionError: NSError?
        converter.convert(to: converted, error: &conversionError) { _, status in
            if fed {
                status.pointee = .endOfStream
                return nil
            }
            fed = true
            status.pointee = .haveData
            return native
        }
        if let conversionError { throw conversionError }
        return converted
    }
}
```

- [ ] **Step 4: Build and fix SDK-name drift**

Run: `swift build 2>&1 | head -50`
Expected: compiles. If the compiler rejects a SpeechAnalyzer-family name
(e.g. `contextualStrings` subscripting, `setContext`, stream types), consult
the SDK interface (`swift build` errors name the candidates; or
`sed -n` over the `.swiftinterface` under the macOS 26 SDK's
`Speech.framework`) and adapt. Do not change the public surface of
`AppleSpeechTranscriber`.

- [ ] **Step 5: Run the buffer tests**

Run: `swift test --filter AppleSpeechTranscriberTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/LuxiconKit/AppleSpeechTranscriber.swift Tests/LuxiconKitTests/AppleSpeechTranscriberTests.swift
git commit -m "Kit: AppleSpeechTranscriber engine over SpeechAnalyzer (iOS 26+)"
```

---

### Task 3: `ASREngine.appleSpeech`, resolved default, and pipeline wiring

**Files:**
- Modify: `Sources/LuxiconKit/MeetingPipeline.swift` (`ASREngine`, `MeetingPipeline.load`)
- Modify: `Sources/LuxiconCLI/LuxiconCLI.swift:192` (engine flag error text)
- Test: `Tests/LuxiconKitTests/PipelineLogicTests.swift`

**Interfaces:**
- Consumes: `AppleSpeechTranscriber.load(progress:)` (Task 2).
- Produces:
  ```swift
  public enum ASREngine: String, Codable, Sendable { case parakeet, appleSpeech }
  ASREngine.resolvedDefault() -> ASREngine                     // OS-gated
  ASREngine.resolvedDefault(appleSpeechAvailable: Bool) -> ASREngine  // testable
  ```

- [ ] **Step 1: Write the failing tests**

In `Tests/LuxiconKitTests/PipelineLogicTests.swift`:

```swift
@Test func resolvedDefaultPrefersAppleSpeechWhenAvailable() {
    #expect(ASREngine.resolvedDefault(appleSpeechAvailable: true) == .appleSpeech)
    #expect(ASREngine.resolvedDefault(appleSpeechAvailable: false) == .parakeet)
}

@Test func appleSpeechRawValueIsStable() {
    // Persisted in store.json and passed as a CLI flag — must never change.
    #expect(ASREngine.appleSpeech.rawValue == "appleSpeech")
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter PipelineLogicTests`
Expected: FAIL — `appleSpeech` case does not exist (compile error).

- [ ] **Step 3: Implement**

In `Sources/LuxiconKit/MeetingPipeline.swift`, extend the enum. It already has
a custom tolerant `init(from:)` (added when Qwen3 was retired — unknown raw
values decode to `.parakeet`); keep it exactly as is, add the case and the
resolver:

```swift
public enum ASREngine: String, Codable, Sendable {
    /// Parakeet TDT — CoreML/ANE, fast, the pre-iOS-26 default.
    case parakeet
    /// Apple SpeechTranscriber — system model, out-of-process, iOS 26+.
    case appleSpeech

    // (existing tolerant init(from:) stays unchanged)

    /// Default engine for this device: Apple's system transcriber where the
    /// OS supports it, otherwise Parakeet. Locale/asset failures surface at
    /// load time and fall back there — this is only the cheap OS gate.
    public static func resolvedDefault() -> ASREngine {
        if #available(iOS 26.0, macOS 26.0, *) {
            return resolvedDefault(appleSpeechAvailable: true)
        }
        return resolvedDefault(appleSpeechAvailable: false)
    }

    /// Testable seam for `resolvedDefault()`.
    public static func resolvedDefault(appleSpeechAvailable: Bool) -> ASREngine {
        appleSpeechAvailable ? .appleSpeech : .parakeet
    }
}
```

Also update the enum's leading doc comment: it currently says the enum is
"single-cased today" pending a successor engine — this task delivers that
successor, so rewrite it to describe the two cases.

In `MeetingPipeline.load(engine:progress:)`, add the branch. The `appleSpeech`
case must throw if the OS is too old (an explicit request for an unavailable
engine is an error; automatic selection never requests it on old OSes):

```swift
        case .appleSpeech:
            guard #available(iOS 26.0, macOS 26.0, *) else {
                throw EngineUnavailableError(
                    reason: "Apple speech transcription requires iOS 26 or macOS 26")
            }
            asr = try await AppleSpeechTranscriber.load { p, stage in
                progress?(0.5 + p * 0.5, stage)
            }
```

LuxiconKit has no shared error type (the pattern is scoped types like
`SyncPushError`), and `AppleSpeechTranscriber.LoadError` can't be referenced
from the `#available` *else* branch — so define next to `ASREngine`, ungated:

```swift
/// Load-time engine failure; the app catches it to fall back to Parakeet.
public struct EngineUnavailableError: Error, LocalizedError {
    public let reason: String
    public init(reason: String) { self.reason = reason }
    public var errorDescription: String? { reason }
}
```

In `Sources/LuxiconCLI/LuxiconCLI.swift:192`, update the flag error message:

```swift
                guard let parsed = ASREngine(rawValue: try value(after: "--engine", at: i)) else {
                    throw ValidationError("--engine expects parakeet or appleSpeech")
                }
```

(`init(rawValue:)` stays strict for the CLI — the tolerant decode is only the
Codable path.)

- [ ] **Step 4: Run tests and build**

Run: `swift test && swift build`
Expected: PASS, builds clean.

- [ ] **Step 5: Commit**

```bash
git add Sources/LuxiconKit/MeetingPipeline.swift Sources/LuxiconCLI/LuxiconCLI.swift Tests/LuxiconKitTests/PipelineLogicTests.swift
git commit -m "Kit/CLI: appleSpeech ASR engine case with OS-gated resolved default"
```

---

### Task 4: CLI verification on macOS 26 (checkpoint — needs a human ear)

No code. Verifies the engine end-to-end before app work, per the repo's
verify-with-CLI convention.

**Files:** none (verification only)

- [ ] **Step 1: Build the CLI with Metal shaders**

```bash
bash scripts/build_mlx_metallib.sh debug && swift build
```

- [ ] **Step 2: Transcribe a known recording with both engines**

Use any 16 kHz-loadable recording with two speakers (a session WAV pushed to
`~/Luxicon`, or record ~1 minute). Then:

```bash
.build/debug/luxicon-cli transcribe <file.wav> --engine appleSpeech --out /tmp/apple-run
.build/debug/luxicon-cli transcribe <file.wav> --engine parakeet   --out /tmp/parakeet-run
```

Expected: the appleSpeech run prints an asset-download stage on first use,
then produces a diarized transcript. Compare the two markdown outputs.

- [ ] **Step 3: Verify vocabulary biasing does no harm**

```bash
.build/debug/luxicon-cli transcribe <file.wav> --engine appleSpeech --vocab "Davidson,Luxicon" --out /tmp/apple-vocab-run
```

Expected: transcript quality unchanged or better; no crash from
`AnalysisContext`. (Whether biasing measurably helps short clips is the spec's
open question #2 — record the observation in the PR description, don't block.)

- [ ] **Step 4: Report findings to the user before proceeding**

This is a review checkpoint: paste both transcripts' first ~10 turns and note
quality, speed, and any API-name adaptations made in Task 2.

---

### Task 5: App — engine choice becomes optional (`nil` = automatic)

**Files:**
- Modify: `App/Sources/Store.swift` (property ~line 84, `Persisted` ~line 150, `load()` ~line 233, `save()`/`Persisted` construction ~line 275)

**Interfaces:**
- Consumes: `ASREngine.resolvedDefault()` (Task 3).
- Produces (used by Task 6's picker and existing call sites):
  ```swift
  // Store:
  var asrEngineChoice: ASREngine?          // nil = automatic; persisted
  var asrEngine: ASREngine { get }         // computed: choice ?? resolvedDefault()
  ```

- [ ] **Step 1: Replace the stored property**

In `App/Sources/Store.swift` (~line 84), replace `var asrEngine: ASREngine = .parakeet` with:

```swift
    /// Explicit engine choice from settings; nil means automatic
    /// (Apple's system transcriber on iOS 26+, else Parakeet).
    var asrEngineChoice: ASREngine?
    var asrEngine: ASREngine { asrEngineChoice ?? .resolvedDefault() }
```

`SessionProcessing.swift:55` (`let engine = asrEngine`) keeps working unchanged.

- [ ] **Step 2: Update `Persisted` and `load()`**

In `Persisted` (~line 150), keep the legacy field (harmless to decode; the
tolerant `ASREngine` decoder maps any old value to `.parakeet`) and add the
new one:

```swift
        /// Legacy engine field: ignored on read, never written. Post-Qwen3
        /// retirement it can only decode to .parakeet, and a default was
        /// never distinguishable from a choice under this key anyway.
        var asrEngine: ASREngine?
        var asrEngineChoice: ASREngine?
```

In `load()` (~line 233), replace `asrEngine = persisted.asrEngine ?? .parakeet` with:

```swift
        asrEngineChoice = persisted.asrEngineChoice
```

- [ ] **Step 3: Update `save()`**

Where `save()` constructs `Persisted` (~line 275), replace `asrEngine: asrEngine` with:

```swift
            asrEngine: nil,                    // legacy key: read-only (see Persisted)
            asrEngineChoice: asrEngineChoice,
```

(If `Persisted`'s encoder writes explicit `null`s and that bothers you, it's
harmless — older builds decode `null` as nil. Do not add custom encoding.)

- [ ] **Step 4: Build the app**

```bash
cd App && xcodebuild -project Luxicon.xcodeproj -scheme Luxicon \
  -destination 'generic/platform=iOS' -configuration Release -allowProvisioningUpdates build 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add App/Sources/Store.swift
git commit -m "App: engine preference becomes optional choice; automatic default resolves at use"
```

---

### Task 6: App — Transcription picker, load-time fallback, README privacy note

**Files:**
- Modify: `App/Sources/Views/MyVoiceView.swift` (new section after `aiSummariesSection`, ~line 97)
- Modify: `App/Sources/PipelineService.swift` (`ensureLoaded` fallback)
- Modify: `README.md` (privacy paragraph)

**Interfaces:**
- Consumes: `Store.asrEngineChoice` (Task 5), `EngineUnavailableError`/`AppleSpeechTranscriber.LoadError` (Tasks 2–3).

- [ ] **Step 1: Add the Transcription section to `MyVoiceView`**

Where the retired Qwen3 engine picker used to sit — after the People-sync
`SyncSourceSection`, before the Mac sync section (~line 141) — following the
file's existing Section style:

```swift
            if #available(iOS 26.0, *) {
                @Bindable var store = store
                Section {
                    Picker("Engine", selection: $store.asrEngineChoice) {
                        Text("Automatic (recommended)").tag(ASREngine?.none)
                        Text("Apple").tag(ASREngine?.some(.appleSpeech))
                        Text("Luxicon").tag(ASREngine?.some(.parakeet))
                    }
                    .onChange(of: store.asrEngineChoice) { store.save() }
                } header: {
                    Text("Transcription")
                } footer: {
                    Text("Automatic uses Apple's on-device speech model on this iPhone and falls back to Luxicon's built-in engine if it isn't available. Everything stays on the device either way.")
                }
            }
```

(On iOS 18–25 the section is hidden: Parakeet is the only option there, so
there is nothing to pick.)

- [ ] **Step 2: Add load-time fallback in `PipelineService.ensureLoaded`**

Replace the `let loaded = try await MeetingPipeline.load(...)` line with:

```swift
        let loaded: MeetingPipeline
        do {
            loaded = try await MeetingPipeline.load(engine: engine, progress: progress)
        } catch where engine == .appleSpeech {
            // System transcriber unavailable (locale/asset) — never block a
            // meeting on it. Cache under the requested key so we don't retry
            // (and re-fail) the download every session this run.
            progress?(0, "System transcription unavailable — using built-in engine")
            loaded = try await MeetingPipeline.load(engine: .parakeet, progress: progress)
        }
```

- [ ] **Step 3: Update README privacy copy**

In `README.md`, find the privacy paragraph (the load-bearing App Store copy —
`grep -n "on-device\|on device" README.md`) and add one sentence to it, matching
the surrounding tone:

> On iOS 26 and later, transcription can use Apple's built-in speech model — a
> system component that Apple's OS downloads and runs on-device, the same way
> keyboard dictation works; audio still never leaves the phone.

Do not restructure the section; this is an addition, not a rewrite.

- [ ] **Step 4: Build and install on device**

```bash
cd App && xcodebuild -project Luxicon.xcodeproj -scheme Luxicon \
  -destination 'generic/platform=iOS' -configuration Release -allowProvisioningUpdates build 2>&1 | tail -5
xcrun devicectl device install app --device <id> \
  ~/Library/Developer/Xcode/DerivedData/Luxicon-*/Build/Products/Release-iphoneos/Luxicon.app
```

Expected: `BUILD SUCCEEDED`, install completes.

- [ ] **Step 5: On-device verification (checkpoint — needs the user's iPhone)**

With the user: record or re-transcribe a real 1-on-1 on the device with the
picker on Automatic. Verify (a) the transcript is diarized and labeled as
before, (b) Settings shows the Transcription section, (c) a long recording
survives without a jetsam kill (the whole point of out-of-process inference),
and (d) with Airplane Mode + never-downloaded asset, processing falls back to
Parakeet instead of failing.

- [ ] **Step 6: Commit**

```bash
git add App/Sources/Views/MyVoiceView.swift App/Sources/PipelineService.swift README.md
git commit -m "App: transcription engine picker, appleSpeech load fallback, privacy copy"
```

---

## Verification checklist (post-plan)

- `swift test` green; no test downloads anything (run once with network off to prove it).
- `luxicon-cli transcribe --engine appleSpeech` produces a diarized transcript on macOS 26.
- Device: automatic engine resolves to Apple on the iPhone (iOS 26+), transcript quality ≥ Parakeet, long meeting survives.
- store.json round-trip: new build writes `asrEngineChoice`; confirm a copy of the file decodes under the previous release's `Persisted` shape (keys it doesn't know are ignored).
