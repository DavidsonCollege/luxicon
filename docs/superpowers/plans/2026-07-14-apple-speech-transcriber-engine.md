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

---

### Task 1: `ASRContext` — richer context type through the `TurnTranscriber` seam

The protocol currently passes `context: String?` (prose, for Qwen3's decoder).
Apple's `AnalysisContext.contextualStrings` wants discrete terms, not prose.
Introduce a small struct carrying both, and a `VocabularyCorrector.contextTerms`
producer.

**Files:**
- Modify: `Sources/LuxiconKit/MeetingPipeline.swift` (protocol, both engine extensions, `process`, `transcribeBounded`)
- Modify: `Sources/LuxiconKit/Vocabulary.swift` (add `contextTerms(for:)`)
- Test: `Tests/LuxiconKitTests/VocabularyTests.swift`, `Tests/LuxiconKitTests/PipelineLogicTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct ASRContext: Sendable {
      public var prose: String?      // sentence-form biasing (Qwen3)
      public var terms: [String]     // discrete terms (Apple contextualStrings)
      public init(prose: String?, terms: [String])
  }
  // protocol change:
  func transcribeTurn(_ audio: [Float], sampleRate: Int, context: ASRContext?) -> TranscriptionResult
  // new producer:
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

- [ ] **Step 3: Implement `contextTerms` and refactor `contextString` over it**

In `Sources/LuxiconKit/Vocabulary.swift`, replace the body of `contextString(for:)` and add the new function:

```swift
    /// Discrete vocabulary terms for engines that bias on term lists
    /// (Apple SpeechTranscriber's contextual strings).
    public static func contextTerms(for entries: [VocabularyEntry]) -> [String] {
        entries
            .map { $0.term.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Context prompt handed to prose-context ASR engines (Qwen3-ASR).
    public static func contextString(for entries: [VocabularyEntry]) -> String? {
        let terms = contextTerms(for: entries)
        guard !terms.isEmpty else { return nil }
        return "This conversation may mention the following names and terms: "
            + terms.joined(separator: ", ") + "."
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter VocabularyTests`
Expected: PASS (all existing vocabulary tests still green — `contextString` behavior unchanged).

- [ ] **Step 5: Introduce `ASRContext` and change the protocol**

In `Sources/LuxiconKit/MeetingPipeline.swift`:

Add above the protocol:

```swift
/// Vocabulary context for ASR engines, in both shapes engines consume.
public struct ASRContext: Sendable {
    /// Sentence-form biasing prompt (Qwen3-ASR decoder context).
    public var prose: String?
    /// Discrete terms (Apple SpeechTranscriber contextual strings).
    public var terms: [String]

    public init(prose: String?, terms: [String]) {
        self.prose = prose
        self.terms = terms
    }
}
```

Change the protocol method:

```swift
public protocol TurnTranscriber: AnyObject {
    /// Whether `context` is honored (decoder-level vocabulary biasing).
    var supportsContext: Bool { get }
    func transcribeTurn(_ audio: [Float], sampleRate: Int, context: ASRContext?) -> TranscriptionResult
}
```

Update both existing conformances:

```swift
extension ParakeetASRModel: TurnTranscriber {
    public var supportsContext: Bool { false }
    public func transcribeTurn(_ audio: [Float], sampleRate: Int, context: ASRContext?) -> TranscriptionResult {
        transcribeWithLanguage(audio: audio, sampleRate: sampleRate, language: nil)
    }
}

extension Qwen3ASRModel: TurnTranscriber {
    public var supportsContext: Bool { true }
    public func transcribeTurn(_ audio: [Float], sampleRate: Int, context: ASRContext?) -> TranscriptionResult {
        let text = transcribe(audio: audio, sampleRate: sampleRate, context: context?.prose)
        return TranscriptionResult(text: text)
    }
}
```

In `process(...)` (step 4, "Transcribe each turn"), replace the context line:

```swift
        let context: ASRContext? = asr.supportsContext
            ? ASRContext(
                prose: VocabularyCorrector.contextString(for: vocabulary),
                terms: VocabularyCorrector.contextTerms(for: vocabulary))
            : nil
```

Update `transcribeBounded`'s signature (`context: String?` → `context: ASRContext?`); its body only forwards `context`, so nothing else changes.

- [ ] **Step 6: Update the test mock's signature**

In `Tests/LuxiconKitTests/PipelineLogicTests.swift` line ~164, the mock transcriber's
`transcribeTurn(_ audio:sampleRate:context: String?)` becomes `context: ASRContext?`.
The `transcribeBounded(..., context: nil)` call sites need no change.

- [ ] **Step 7: Run the full suite**

Run: `swift test`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/LuxiconKit/MeetingPipeline.swift Sources/LuxiconKit/Vocabulary.swift Tests/LuxiconKitTests/VocabularyTests.swift Tests/LuxiconKitTests/PipelineLogicTests.swift
git commit -m "Kit: pass vocabulary context as ASRContext (prose + terms) through TurnTranscriber"
```

---

### Task 2: `AppleSpeechTranscriber` engine

**Files:**
- Create: `Sources/LuxiconKit/AppleSpeechTranscriber.swift`
- Test: `Tests/LuxiconKitTests/AppleSpeechTranscriberTests.swift` (buffer conversion only — offline)

**Interfaces:**
- Consumes: `ASRContext`, `TurnTranscriber`, `TranscriptionResult` (from Task 1 / speech-swift).
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
      public func transcribeTurn(_ audio: [Float], sampleRate: Int, context: ASRContext?) -> TranscriptionResult
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
        _ audio: [Float], sampleRate: Int, context: ASRContext?
    ) -> TranscriptionResult {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result = TranscriptionResult(text: "")
        let work = Task { [locale, analyzerFormat] in
            defer { semaphore.signal() }
            do {
                let text = try await Self.analyze(
                    audio: audio, sampleRate: sampleRate, locale: locale,
                    format: analyzerFormat, terms: context?.terms ?? [])
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
  public enum ASREngine: String, Codable, Sendable { case parakeet, qwen3, appleSpeech }
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

In `Sources/LuxiconKit/MeetingPipeline.swift`, extend the enum:

```swift
/// Which ASR engine transcribes speaker turns.
public enum ASREngine: String, Codable, Sendable {
    /// Parakeet TDT — CoreML/ANE, fast, the pre-iOS-26 default.
    case parakeet
    /// Qwen3-ASR 0.6B 4-bit — MLX/GPU, supports vocabulary context injection.
    case qwen3
    /// Apple SpeechTranscriber — system model, out-of-process, iOS 26+.
    case appleSpeech

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
                    throw ValidationError("--engine expects parakeet, qwen3, or appleSpeech")
                }
```

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

In `Persisted` (~line 150), keep the legacy field and add the new one:

```swift
        /// Legacy engine field: read-only for migration, never written.
        /// (No released build had a picker, so a persisted "parakeet" was a
        /// default, not a choice; only a hand-set "qwen3" counts as one.)
        var asrEngine: ASREngine?
        var asrEngineChoice: ASREngine?
```

In `load()` (~line 233), replace `asrEngine = persisted.asrEngine ?? .parakeet` with:

```swift
        asrEngineChoice = persisted.asrEngineChoice
            ?? (persisted.asrEngine == .qwen3 ? .qwen3 : nil)
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

After `aiSummariesSection` (~line 97), following the file's existing Section style:

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

(On iOS 18–25 the section is hidden: Parakeet is the only real option, and
Qwen3 stays a CLI/debug engine as today.)

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
