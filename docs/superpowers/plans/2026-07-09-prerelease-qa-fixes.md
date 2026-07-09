# Pre-Release QA Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix all six pre-release blocker groups from the 2026-07-09 QA survey: sync feature broken on device, App Store upload validation, privacy-claim contradictions, recorder data-loss paths, store data-loss paths, and small cleanups + docs.

**Architecture:** No new subsystems. Changes are contained hardening of existing modules: `LuxiconKit` sync (cancellable timeouts), `LuxiconMCP` listener (frame cap), the app's `Recorder`/`Store` (interruption handling, quarantine-on-corrupt, Keychain), plus project config and documentation.

**Tech Stack:** Swift 6 / SwiftPM, swift-testing (`@Test`/`#expect`), xcodegen, Network.framework, AVFoundation, Security.framework.

## Global Constraints

- App deployment target: iOS 18.0; package platforms macOS 15 / iOS 18 (`Package.swift:6-9`).
- Swift 6 strict concurrency: `Task<Success, _>` requires `Success: Sendable` — `MeetingPipeline`/`MeetingSummarizer` are NOT Sendable; do not store them in `Task` values.
- Tests are swift-testing style (`import Testing`, `@Test`, `#expect`), run with `swift test` on macOS, no models/network required. Use `@testable import LuxiconKit`.
- Bundle ID `edu.davidson.luxicon`; Bonjour type `_luxicon._tcp`; sync port 51234.
- Marketing version "1.0", build 6 (already bumped in working tree — keep).
- The working tree already contains a correct-but-incomplete widget-version fix in `App/WidgetsInfo.plist` + `App/project.yml` — fold it into Task 1, do not revert it.
- Every commit message ends with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Backup policy decision (made): recordings/transcripts REMAIN in device backups (excluding them would silently lose data on phone migration); we disclose it in docs instead, and set `completeUnlessOpen` file protection.
- Repo root: `/Users/jdmills/Documents/GitHub/sitdown`. All commands run there unless noted.

---

### Task 1: Local-network Info.plist keys + unified target versions

**Files:**
- Modify: `App/project.yml` (app target `info.properties`; move versions to project-level `settings`)
- Modify: `App/Info.plist` (add the two keys so the checked-in plist matches)
- Already modified in tree (keep, commit): `App/WidgetsInfo.plist`, `App/project.yml` widget `info.properties`

**Interfaces:**
- Produces: `NSBonjourServices: [_luxicon._tcp]` + `NSLocalNetworkUsageDescription` available to the app at runtime; both targets share one `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`.

- [ ] **Step 1: Edit `App/project.yml`.** In the `Luxicon` target's `info.properties`, after the `NSMicrophoneUsageDescription` block, add:

```yaml
        NSLocalNetworkUsageDescription: >-
          Luxicon uses the local network only if you set up Mac sync: to find
          your Mac and send it the transcripts you choose to sync. Without Mac
          sync, the local network is never used.
        NSBonjourServices:
          - _luxicon._tcp
```

Then unify versions: add a top-level `settings` block (after `packages:`, before `targets:`):

```yaml
settings:
  base:
    MARKETING_VERSION: "1.0"
    CURRENT_PROJECT_VERSION: 6
```

and DELETE the `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` lines from both targets' `settings.base` (Luxicon currently has 6, LuxiconWidgets still has stale 5).

- [ ] **Step 2: Edit `App/Info.plist`** to match (keys are alphabetical; insert after `ITSAppUsesNonExemptEncryption` and before `NSMicrophoneUsageDescription`):

```xml
	<key>NSBonjourServices</key>
	<array>
		<string>_luxicon._tcp</string>
	</array>
	<key>NSLocalNetworkUsageDescription</key>
	<string>Luxicon uses the local network only if you set up Mac sync: to find your Mac and send it the transcripts you choose to sync. Without Mac sync, the local network is never used.</string>
```

- [ ] **Step 3: Verify.** Run: `plutil -lint App/Info.plist && plutil -lint App/WidgetsInfo.plist` → both "OK". If `which xcodegen` succeeds, also run `cd App && xcodegen generate && cd ..` and confirm no errors.

- [ ] **Step 4: Commit** (includes the pre-existing widget plist/version changes):

```bash
git add App/project.yml App/Info.plist App/WidgetsInfo.plist
git commit -m "Fix Mac sync prerequisites and widget versioning

- Add NSLocalNetworkUsageDescription + NSBonjourServices (_luxicon._tcp):
  without these iOS denies the Bonjour browse and the sync feature cannot
  work on device.
- Widget extension now inherits MARKETING_VERSION/CURRENT_PROJECT_VERSION
  from project-level settings; the hardcoded 1.0/1 in WidgetsInfo.plist
  failed App Store Connect upload validation against the app's build.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Sync push timeout actually fires (cancellable discovery + send)

The bug: `withTimeout`'s task group cannot exit because `discoverListener()` and `send()` park on continuations that ignore cancellation; `.waiting` states are unhandled, so a missing Mac or a denied local-network permission hangs `push()` forever.

**Files:**
- Modify: `Sources/LuxiconKit/SyncPusher.swift`
- Test: `Tests/LuxiconKitTests/SyncTests.swift` (create)

**Interfaces:**
- Consumes: `LuxiconSync.parameters(token:)`, `LuxiconSync.frame(_:)`, `Once` (existing in file).
- Produces: `LuxiconSync.withTimeout` becomes `static` (internal) for tests, same signature. `SyncPushError` gains case `localNetworkDenied(String)`. `LuxiconSync.push` signature unchanged.

- [ ] **Step 1: Write failing tests** — create `Tests/LuxiconKitTests/SyncTests.swift`:

```swift
import Foundation
import Testing
@testable import LuxiconKit

@Suite struct SyncTimeoutTests {
    @Test func timeoutFiresOnCancellableSlowWork() async {
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: SyncPushError.self) {
            try await LuxiconSync.withTimeout(0.2, onTimeout: SyncPushError.noListenerFound) {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
        // The old implementation hung here for the full sleep; must return fast.
        #expect(clock.now - start < .seconds(5))
    }

    @Test func fastWorkWinsTheRace() async throws {
        let value = try await LuxiconSync.withTimeout(5, onTimeout: SyncPushError.noListenerFound) {
            42
        }
        #expect(value == 42)
    }
}

@Suite struct SyncHelperTests {
    @Test func sanitizedFilenameBlocksTraversal() {
        #expect(!LuxiconSync.sanitizedFilename("../../etc/passwd").contains("/"))
        #expect(!LuxiconSync.sanitizedFilename("..\\x").contains("\\"))
        #expect(LuxiconSync.sanitizedFilename(".sync-token").hasPrefix("session-"))
        #expect(LuxiconSync.sanitizedFilename("").hasPrefix("session-"))
        #expect(LuxiconSync.sanitizedFilename("a:b").hasSuffix(".json"))
        #expect(LuxiconSync.sanitizedFilename("Sam 2026-07-09.json") == "Sam 2026-07-09.json")
    }

    @Test func frameIsLengthPrefixed() {
        let payload = Data("hello".utf8)
        let framed = LuxiconSync.frame(payload)
        #expect(framed.count == 4 + payload.count)
        let length = framed.prefix(4).withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self).bigEndian) }
        #expect(length == payload.count)
        #expect(framed.dropFirst(4) == payload)
    }

    @Test func tokenIsLongAndInAlphabet() {
        let token = LuxiconSync.generateToken()
        #expect(token.count == 20)
        let alphabet = Set("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        #expect(token.allSatisfy { alphabet.contains($0) })
    }
}
```

- [ ] **Step 2: Run to verify failure.** Run: `swift test --filter SyncTimeoutTests 2>&1 | tail -20`
Expected: compile error — `withTimeout` is private (or, if made internal first, the timeout test hangs/fails). Either failure mode confirms the test bites.

- [ ] **Step 3: Implement** in `Sources/LuxiconKit/SyncPusher.swift`:

(a) Add error case — replace the `SyncPushError` enum body:

```swift
public enum SyncPushError: Error, LocalizedError {
    case noListenerFound
    case connectionFailed(String)
    case noAcknowledgement
    case localNetworkDenied(String)

    public var errorDescription: String? {
        switch self {
        case .noListenerFound:
            return "No Mac listener found on this network. Is `luxicon-mcp listen` running?"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason) (check the pairing token)."
        case .noAcknowledgement:
            return "The listener did not confirm the transfer."
        case .localNetworkDenied(let reason):
            return "Local network access was blocked (\(reason)). Check Settings → Privacy & Security → Local Network → Luxicon."
        }
    }
}
```

(b) Make `withTimeout` internal: change `private static func withTimeout` → `static func withTimeout`. Body unchanged.

(c) Replace `discoverListener()` — cancellable, `.waiting`-aware:

```swift
    private static func discoverListener() async throws -> NWEndpoint {
        let browser = NWBrowser(
            for: .bonjour(type: serviceType, domain: nil),
            using: NWParameters())
        let once = Once()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                browser.browseResultsChangedHandler = { results, _ in
                    if let first = results.first {
                        once.run {
                            browser.cancel()
                            continuation.resume(returning: first.endpoint)
                        }
                    }
                }
                browser.stateUpdateHandler = { state in
                    switch state {
                    case .failed(let error):
                        once.run {
                            browser.cancel()
                            continuation.resume(
                                throwing: SyncPushError.connectionFailed("\(error)"))
                        }
                    case .waiting(let error):
                        // Policy denial (Local Network permission off) parks the
                        // browser here forever — fail fast with the real reason.
                        once.run {
                            browser.cancel()
                            continuation.resume(
                                throwing: SyncPushError.localNetworkDenied("\(error)"))
                        }
                    case .cancelled:
                        once.run { continuation.resume(throwing: CancellationError()) }
                    default:
                        break
                    }
                }
                browser.start(queue: .global(qos: .userInitiated))
            }
        } onCancel: {
            // Drives the browser to .cancelled, which resumes the continuation
            // — this is what lets withTimeout's group actually exit.
            browser.cancel()
        }
    }
```

(d) Replace `send(_:to:token:)` — cancellable:

```swift
    private static func send(_ push: Push, to endpoint: NWEndpoint, token: String) async throws {
        let data = try JSONEncoder().encode(push)
        let connection = NWConnection(to: endpoint, using: parameters(token: token))
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PushSender(connection: connection, data: data, continuation: continuation).start()
            }
        } onCancel: {
            // Drives the connection to .cancelled → PushSender resumes the
            // continuation; without this a dead Mac hangs the push forever.
            connection.cancel()
        }
    }
```

(e) In `PushSender.start()`, replace the `switch state` with (adds `.waiting`):

```swift
            switch state {
            case .ready:
                sendPayload()
            case .waiting(let error):
                // .waiting retries indefinitely (host offline, port closed);
                // for a LAN push, failing fast beats hanging until timeout.
                fail("\(error)")
            case .failed(let error):
                fail("\(error)")
            case .cancelled:
                once.run { continuation.resume(throwing: SyncPushError.noAcknowledgement) }
            default:
                break
            }
```

- [ ] **Step 4: Run tests.** Run: `swift test --filter "SyncTimeoutTests|SyncHelperTests" 2>&1 | tail -5` → all pass, fast. Then full `swift test 2>&1 | tail -3` → all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/LuxiconKit/SyncPusher.swift Tests/LuxiconKitTests/SyncTests.swift
git commit -m "Fix sync push hanging forever when the Mac is unreachable

The timeout task group could never exit: discovery and send parked on
continuations that ignored cancellation, and .waiting states (Mac offline,
Local Network permission denied) were unhandled. Discovery and send are now
cancellable, .waiting fails fast, and a denied local-network browse surfaces
a Settings hint instead of hanging 'Push All to Mac' forever.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Listener frame cap + atomic library writes

**Files:**
- Modify: `Sources/LuxiconKit/LuxiconSync.swift` (add `maxFrameBytes`)
- Modify: `Sources/LuxiconMCP/SyncListener.swift` (enforce cap; atomic write)
- Test: `Tests/LuxiconKitTests/SyncTests.swift` (extend)

**Interfaces:**
- Produces: `LuxiconSync.maxFrameBytes: Int` (64 MiB), used by the listener; pushers never exceed it (a transcript export is KBs).

- [ ] **Step 1: Add failing test** to `SyncHelperTests` in `Tests/LuxiconKitTests/SyncTests.swift`:

```swift
    @Test func frameCapIsSane() {
        // The listener buffers a whole frame in RAM; the cap bounds that.
        #expect(LuxiconSync.maxFrameBytes == 64 * 1024 * 1024)
    }
```

- [ ] **Step 2: Run to verify failure.** `swift test --filter frameCapIsSane 2>&1 | tail -5` → compile error (symbol missing).

- [ ] **Step 3: Implement.** In `Sources/LuxiconKit/LuxiconSync.swift`, after `public static let defaultPort: UInt16 = 51234`:

```swift
    /// Upper bound on one framed push. The receiver buffers a whole frame in
    /// memory, so this caps what a (paired) peer can make it allocate.
    public static let maxFrameBytes = 64 * 1024 * 1024
```

In `Sources/LuxiconMCP/SyncListener.swift`, in `readLength()`, after `expected = ...`:

```swift
            guard expected > 0, expected <= LuxiconSync.maxFrameBytes else {
                print("Rejected push: declared size \(expected) bytes is out of bounds")
                connection.cancel(); return
            }
```

And in `store(_:)`, make the write atomic (a crash mid-write must not leave a truncated JSON the library then silently skips):

```swift
            try push.payload.write(to: libraryURL.appendingPathComponent(filename), options: .atomic)
```

- [ ] **Step 4: Run tests.** `swift test 2>&1 | tail -3` → all pass. Also `swift build` (builds the MCP target).

- [ ] **Step 5: Commit**

```bash
git add Sources/LuxiconKit/LuxiconSync.swift Sources/LuxiconMCP/SyncListener.swift Tests/LuxiconKitTests/SyncTests.swift
git commit -m "Cap sync frames at 64 MiB and write library files atomically

The listener buffered up to 4 GiB per connection based on an
attacker-supplied length prefix, and a crash mid-write could leave a
truncated JSON that the library scanner silently skips.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Dead code removal

**Files:**
- Modify: `Sources/LuxiconKit/WAVFile.swift` (delete `write(samples:sampleRate:to:)`, lines 42-44)
- Modify: `Sources/LuxiconKit/Vocabulary.swift` (delete `similarity`; fix `VocabularyCSV` doc comment on line 7)
- Modify: `Sources/LuxiconKit/MeetingPipeline.swift` (drop `CaseIterable` from `ASREngine`, line 34)
- Modify: `App/Sources/LiveCaptioner.swift` (delete `setSuspended(_:)`, lines 63-66)
- Modify: `Tests/LuxiconKitTests/VocabularyTests.swift` (delete `similarityMetric` test, lines 56-60)

**Interfaces:**
- Consumes: nothing. Produces: nothing — all five symbols verified unreferenced by the 2026-07-09 dead-code audit; `distance(_:_:)` in Vocabulary.swift stays (production uses it).

- [ ] **Step 1: Delete the five items.**
  - `WAVFile.swift`: remove the whole `public static func write(samples:sampleRate:to:)` function.
  - `Vocabulary.swift`: remove `static func similarity(_ a: String, _ b: String) -> Double { ... }` (keep `distance`). On line 7, change the doc comment `(see \`VocabularyCSV\`)` → `(see \`VocabularyJSON\`)`.
  - `MeetingPipeline.swift` line 34: `public enum ASREngine: String, Codable, Sendable, CaseIterable {` → `public enum ASREngine: String, Codable, Sendable {`.
  - `LiveCaptioner.swift`: remove the `setSuspended` function and its doc comment (the lifecycle observers set `sink.suspended` directly).
  - `VocabularyTests.swift`: remove the `@Test func similarityMetric()` block.

- [ ] **Step 2: Verify nothing referenced them.** Run:
`grep -rn "WAVFile.write\|setSuspended\|allCases\|\.similarity(" Sources App Tests --include="*.swift"` → zero hits.

- [ ] **Step 3: Build + test.** `swift build && swift test 2>&1 | tail -3` → pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/LuxiconKit/WAVFile.swift Sources/LuxiconKit/Vocabulary.swift Sources/LuxiconKit/MeetingPipeline.swift App/Sources/LiveCaptioner.swift Tests/LuxiconKitTests/VocabularyTests.swift
git commit -m "Remove dead code found in pre-release audit

WAVFile.write, VocabularyCorrector.similarity (+ its only caller, a test),
ASREngine's unused CaseIterable, LiveCaptioner.setSuspended, and a stale
doc reference to the removed VocabularyCSV format.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Recorder hardening (interruptions, permission, lock leak, disk-full, RAM)

**Files:**
- Modify: `App/Sources/Recorder.swift` (substantial rewrite of lifecycle)
- Modify: `App/Sources/Views/RecordSheetView.swift` (permission gate, duration source, status banners, discard confirmation)
- Modify: `App/Sources/Views/MyVoiceView.swift` (permission gate on enrollment)

**Interfaces:**
- Consumes: `WAVFileWriter` (`append`, `finalize`, `sampleCount`), `WAVFile.repairHeader(url:sampleRate:)`.
- Produces (read by RecordSheetView's TimelineView polling):
  - `Recorder.duration: TimeInterval` — now tally-based, valid for file-backed recordings.
  - `Recorder.isInterrupted: Bool` — true while another audio session holds the mic.
  - `Recorder.runtimeError: String?` — first write/resume failure, human-readable.
  - `Recorder.start(writingTo:)` throws `RecorderError.microphoneAccessDenied` / `.microphoneUnavailable` (LocalizedError).
  - Behavior change: `stop()` returns captured samples ONLY for buffer-backed (no-file) recordings, i.e. enrollment; file-backed recordings return `[]` and callers must use `duration`.

- [ ] **Step 1: Rewrite `App/Sources/Recorder.swift`** — full new file content:

```swift
import Foundation
import AVFoundation
import LuxiconKit

enum RecorderError: LocalizedError {
    case microphoneAccessDenied
    case microphoneUnavailable

    var errorDescription: String? {
        switch self {
        case .microphoneAccessDenied:
            return "Microphone access is off for Luxicon. Turn it on in Settings → Privacy & Security → Microphone."
        case .microphoneUnavailable:
            return "The microphone is unavailable right now."
        }
    }
}

/// Captures microphone audio as 16 kHz mono Float32 (the pipeline's input format).
///
/// When started with a URL, samples stream to disk as they arrive and are NOT
/// kept in memory (a 3-hour meeting would be ~700 MB of Float32); a crash
/// mid-recording loses at most the last chunk — the file is recoverable via
/// `WAVFile.repairHeader`. Without a URL (voice enrollment), samples accumulate
/// in memory and `stop()` returns them.
///
/// Interruptions (phone call, Siri) pause capture; the recorder resumes
/// automatically when the session is handed back and exposes `isInterrupted`
/// so the UI can say so. Write failures (disk full) surface via `runtimeError`
/// instead of being silently swallowed.
final class Recorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var buffer: [Float] = []
    private var sampleTally = 0
    private var converter: AVAudioConverter?
    private var writer: WAVFileWriter?
    private var fileURL: URL?
    private var runtimeErrorStorage: String?
    private var observers: [NSObjectProtocol] = []
    private(set) var isRecording = false
    /// True while another audio session (phone call, Siri) holds the mic.
    private(set) var isInterrupted = false

    /// Called on the audio thread with each converted 16 kHz chunk
    /// (e.g. to feed live transcription). Set before `start`.
    var onSamples: (@Sendable ([Float]) -> Void)?

    static let sampleRate = MeetingPipeline.sampleRate

    private static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(Recorder.sampleRate),
        channels: 1,
        interleaved: false
    )!

    var duration: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Double(sampleTally) / Double(Self.sampleRate)
    }

    /// First capture/write failure, for the UI. Nil while healthy.
    var runtimeError: String? {
        lock.lock(); defer { lock.unlock() }
        return runtimeErrorStorage
    }

    /// RMS level of the most recent chunk, 0–1, for a meter.
    private(set) var level: Float = 0

    /// Start capturing. If `fileURL` is given, audio is continuously persisted
    /// there (crash-safe); the file is finalized on `stop()`.
    func start(writingTo fileURL: URL? = nil) throws {
        guard !isRecording else { return }

        #if os(iOS)
        guard AVAudioApplication.shared.recordPermission != .denied else {
            throw RecorderError.microphoneAccessDenied
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
        #endif

        // Create the writer before taking the lock: a throw while the lock is
        // held would deadlock every UI poll of `duration`.
        let newWriter = try fileURL.map { try WAVFileWriter(url: $0, sampleRate: Self.sampleRate) }
        lock.lock()
        buffer.removeAll()
        sampleTally = 0
        writer = newWriter
        self.fileURL = fileURL
        runtimeErrorStorage = nil
        lock.unlock()

        try startEngine()
        isRecording = true
        isInterrupted = false
        installObservers()
    }

    /// Stop, finalize the on-disk file (if any), and return the in-memory
    /// samples (enrollment recordings only; file-backed recordings return []).
    func stop() -> [Float] {
        guard isRecording else { return [] }
        removeObservers()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        isInterrupted = false
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        lock.lock(); defer { lock.unlock() }
        do {
            try writer?.finalize()
        } catch {
            // Finalize failed (disk full?): the header still claims 0 samples.
            // Patch it from the file size so the captured audio survives.
            if let fileURL {
                try? WAVFile.repairHeader(url: fileURL, sampleRate: Self.sampleRate)
            }
        }
        writer = nil
        fileURL = nil
        return buffer
    }

    // MARK: - Engine lifecycle

    /// (Re)wire the tap and start the engine. Reads the CURRENT input format,
    /// so it is also the recovery path after route/configuration changes.
    private func startEngine() throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let inputFormat = input.outputFormat(forBus: 0)
        // A denied/lost mic reports the invalid 0 Hz format; installing a tap
        // with it raises an uncatchable NSException — bail out first.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.microphoneUnavailable
        }
        converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] pcmBuffer, _ in
            self?.consume(pcmBuffer)
        }
        engine.prepare()
        try engine.start()
    }

    private func resumeCapture() {
        guard isRecording, !engine.isRunning else { return }
        do {
            #if os(iOS)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            try startEngine()
            isInterrupted = false
        } catch {
            setRuntimeError("Recording paused and could not resume: \(error.localizedDescription). Stop to save what was captured.")
        }
    }

    private func setRuntimeError(_ message: String) {
        lock.lock()
        if runtimeErrorStorage == nil { runtimeErrorStorage = message }
        lock.unlock()
    }

    // MARK: - Interruptions (phone call, Siri, route/config changes)

    private func installObservers() {
        let center = NotificationCenter.default
        var installed: [NSObjectProtocol] = []
        #if os(iOS)
        installed.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            self?.handleInterruption(note)
        })
        #endif
        installed.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main
        ) { [weak self] _ in
            // Route change (AirPods in/out): the engine stops and the input
            // format may differ — rewire with the fresh format.
            self?.resumeCapture()
        })
        observers = installed
    }

    private func removeObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
    }

    #if os(iOS)
    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        switch type {
        case .began:
            isInterrupted = true
        case .ended:
            // Always try to resume: for a meeting recorder, silently losing
            // the rest of the conversation is the worst outcome.
            resumeCapture()
        @unknown default:
            break
        }
    }
    #endif

    // MARK: - Capture

    private func consume(_ pcmBuffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = Self.targetFormat.sampleRate / pcmBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(pcmBuffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else { return }

        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return pcmBuffer
        }
        guard error == nil, out.frameLength > 0, let channel = out.floatChannelData?[0] else { return }

        let samples = UnsafeBufferPointer(start: channel, count: Int(out.frameLength))
        var sumSquares: Float = 0
        for s in samples { sumSquares += s * s }
        level = min(1, sqrt(sumSquares / Float(samples.count)) * 6)

        let chunk = Array(samples)
        lock.lock()
        sampleTally += chunk.count
        if writer == nil {
            // Enrollment path: caller consumes the samples from stop().
            buffer.append(contentsOf: chunk)
        } else {
            do {
                try writer?.append(chunk)
            } catch {
                if runtimeErrorStorage == nil {
                    runtimeErrorStorage = "Recording can't be written (storage full?). Stop now — audio up to this point is saved."
                }
            }
        }
        lock.unlock()

        onSamples?(chunk)
    }
}
```

- [ ] **Step 2: Update `App/Sources/Views/RecordSheetView.swift`:**

(a) `begin()` — permission gate (replace the function):

```swift
    private func begin() {
        Task {
            let granted = await AVAudioApplication.requestRecordPermission()
            guard granted else {
                startError = RecorderError.microphoneAccessDenied.errorDescription
                return
            }
            do {
                let fileURL = try store.beginRecording(id: sessionId, person: person)
                recorder.onSamples = captioner.feed
                try recorder.start(writingTo: fileURL)
                store.setRecordingActive(true)
                captioner.start()
                RecordingActivityController.shared.start(personName: person.name)
            } catch {
                startError = "Could not start recording: \(error.localizedDescription)"
            }
        }
    }
```

Add `import AVFoundation` at the top of the file (below `import SwiftUI`).

(b) `stopAndSave()` — duration from the recorder tally, not the returned buffer (which is now empty for file-backed recordings):

```swift
    private func stopAndSave() {
        saving = true
        let duration = recorder.duration
        _ = recorder.stop()
        captioner.stop()
        RecordingActivityController.shared.end()
        do {
            let session = try store.finishRecording(id: sessionId, duration: duration)
            store.startProcessing(session)
            dismiss()
        } catch {
            startError = "Could not save recording: \(error.localizedDescription)"
            saving = false
        }
    }
```

(c) Status banners — inside the `VStack`, directly after the consent `Label(...)` block, add:

```swift
                    if recorder.isInterrupted {
                        Label("Recording paused by another audio session — it resumes automatically when the call ends.",
                              systemImage: "pause.circle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .padding(.horizontal)
                    }
                    if let runtimeError = recorder.runtimeError {
                        Text(runtimeError).font(.footnote).foregroundStyle(.red)
                            .padding(.horizontal)
                    }
```

(d) Discard confirmation — an irrecoverable recording should not vanish on one tap. Add state `@State private var confirmingDiscard = false`, change the toolbar button to `Button("Discard") { confirmingDiscard = true }`, and add after `.interactiveDismissDisabled()`:

```swift
            .confirmationDialog(
                "Discard this recording?", isPresented: $confirmingDiscard, titleVisibility: .visible
            ) {
                Button("Discard Recording", role: .destructive) { discard() }
            } message: {
                Text("The audio cannot be recovered.")
            }
```

- [ ] **Step 3: Update `App/Sources/Views/MyVoiceView.swift`** — same permission gate on enrollment (replace `startEnrollment()`), and add `import AVFoundation` below `import SwiftUI`:

```swift
    private func startEnrollment() {
        errorMessage = nil
        Task {
            let granted = await AVAudioApplication.requestRecordPermission()
            guard granted else {
                errorMessage = RecorderError.microphoneAccessDenied.errorDescription
                return
            }
            do {
                try recorder.start()
                isRecording = true
            } catch {
                errorMessage = "Could not start recording: \(error.localizedDescription)"
            }
        }
    }
```

(Enrollment keeps using `recorder.stop()`'s returned samples — the buffer-backed path still returns them.)

- [ ] **Step 4: Compile check.** `swift build` (LuxiconKit unaffected but cheap). Then if xcodegen exists: `cd App && xcodegen generate && xcodebuild -project Luxicon.xcodeproj -scheme Luxicon -destination 'generic/platform=iOS' -configuration Debug CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5`. Expected: `BUILD SUCCEEDED`. If the environment lacks the iOS SDK/xcodegen, note it and rely on careful review — do not fight the toolchain.

- [ ] **Step 5: Commit**

```bash
git add App/Sources/Recorder.swift App/Sources/Views/RecordSheetView.swift App/Sources/Views/MyVoiceView.swift
git commit -m "Harden the recorder against the ways a meeting gets lost

- Handle AVAudioSession interruptions and route/config changes: a phone
  call mid-1-on-1 previously stopped capture silently and permanently;
  now capture resumes and the UI shows a paused banner.
- Request/check mic permission before starting (denied permission
  previously crashed in installTap with a 0 Hz format).
- Stop holding the whole recording in RAM for file-backed sessions
  (3 h ≈ 700 MB); duration now comes from the sample tally.
- Surface disk-write failures instead of swallowing them; repair the WAV
  header if finalize fails so captured audio survives.
- Fix a lock leak when the WAV writer failed to open (deadlocked the UI).
- Confirm before discarding an irrecoverable recording.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Store hardening (quarantine corrupt library, surface save failures, Keychain, file protection)

**Files:**
- Create: `App/Sources/KeychainStore.swift`
- Modify: `App/Sources/Store.swift`
- Modify: `App/Sources/Views/PeopleListView.swift` (alert)

**Interfaces:**
- Produces:
  - `KeychainStore.string(for:)/set(_:for:)` and `data(for:)/set(_:for:)` — generic-password wrapper, service `edu.davidson.luxicon`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
  - `Store.startupWarning: String?`, `Store.saveError: String?` — shown by PeopleListView.
  - `syncToken`/`vocabularyHeaders` live in the Keychain; `store.json` fields stay in `Persisted` for one-way migration but are written as nil.

- [ ] **Step 1: Create `App/Sources/KeychainStore.swift`:**

```swift
import Foundation
import Security

/// Minimal generic-password wrapper for the app's few secrets (the Mac-sync
/// pairing token and vocabulary request headers). Device-only, available
/// after first unlock so auto-push keeps working in the background.
enum KeychainStore {
    private static let service = "edu.davidson.luxicon"

    static func data(for key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Set or (with nil) delete.
    static func set(_ value: Data?, for key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value else { return }
        var add = base
        add[kSecValueData as String] = value
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func string(for key: String) -> String? {
        data(for: key).map { String(decoding: $0, as: UTF8.self) }
    }

    static func set(_ value: String?, for key: String) {
        set(value.flatMap { $0.isEmpty ? nil : Data($0.utf8) }, for: key)
    }
}
```

- [ ] **Step 2: Modify `App/Sources/Store.swift`:**

(a) Add transient UI state after `@ObservationIgnored var vocabularyLastSyncAttempt: Date?`:

```swift
    /// Set when the persisted library could not be read at launch (the file
    /// is quarantined, never overwritten). Shown once by the root view.
    var startupWarning: String?
    /// Set when persisting the library fails (e.g. storage full).
    var saveError: String?
```

(b) Add Keychain key names near `storeURL`:

```swift
    private static let keychainSyncToken = "syncToken"
    private static let keychainVocabHeaders = "vocabularyHeaders"
```

(c) In `init()`, after the two `createDirectory` calls, set directory protection (new files inherit it; the live recording stays writable because it is already open):

```swift
        for url in [Self.documentsURL, Self.audioDirURL, Self.photosDirURL] {
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUnlessOpen],
                ofItemAtPath: url.path)
        }
```

(d) Replace `load()` — quarantine instead of silently starting empty (the old `try?` path meant one corrupt byte + one `save()` wiped the whole library):

```swift
    func load() {
        // Secrets live in the Keychain; store.json copies (pre-build-6) migrate below.
        syncToken = KeychainStore.string(for: Self.keychainSyncToken) ?? ""
        vocabularyHeaders = KeychainStore.data(for: Self.keychainVocabHeaders)
            .flatMap { try? JSONDecoder().decode([HTTPHeader].self, from: $0) } ?? []

        guard FileManager.default.fileExists(atPath: Self.storeURL.path) else { return }
        let persisted: Persisted
        do {
            let data = try Data(contentsOf: Self.storeURL)
            persisted = try JSONDecoder().decode(Persisted.self, from: data)
        } catch {
            // Never overwrite what we can't read: set it aside so the next
            // save() can't destroy the library, and tell the user.
            let backupName = "store.corrupt-\(Int(Date().timeIntervalSince1970)).json"
            try? FileManager.default.moveItem(
                at: Self.storeURL,
                to: Self.documentsURL.appendingPathComponent(backupName))
            startupWarning = "The session library could not be read, so it was set aside as \(backupName) and Luxicon started fresh. Audio files are untouched. Please report this."
            return
        }
        people = persisted.people
        sessions = persisted.sessions
        myName = persisted.myName
        myPhotoFileName = persisted.myPhotoFileName
        myVoiceEmbedding = persisted.myVoiceEmbedding
        vocabularyEntries = persisted.vocabularyEntries
            ?? (persisted.customVocabulary ?? []).map { VocabularyEntry(term: $0) }
        asrEngine = persisted.asrEngine ?? .parakeet
        vocabularySourceURL = persisted.vocabularySourceURL ?? ""
        vocabularyLastSync = persisted.vocabularyLastSync
        autoSummarize = persisted.autoSummarize ?? true
        syncHost = persisted.syncHost ?? ""
        autoPushToMac = persisted.autoPushToMac ?? false

        // One-way migration: secrets that older builds kept in store.json.
        if let legacyToken = persisted.syncToken, !legacyToken.isEmpty {
            syncToken = legacyToken
            KeychainStore.set(legacyToken, for: Self.keychainSyncToken)
        }
        if let legacyHeaders = persisted.vocabularyHeaders, !legacyHeaders.isEmpty {
            vocabularyHeaders = legacyHeaders
            KeychainStore.set(try? JSONEncoder().encode(legacyHeaders), for: Self.keychainVocabHeaders)
        }
    }
```

(e) Replace `save()` — secrets to Keychain, plaintext fields nil, errors surfaced, protected write:

```swift
    func save() {
        KeychainStore.set(syncToken, for: Self.keychainSyncToken)
        KeychainStore.set(
            vocabularyHeaders.isEmpty ? nil : try? JSONEncoder().encode(vocabularyHeaders),
            for: Self.keychainVocabHeaders)

        let persisted = Persisted(
            people: people, sessions: sessions,
            myName: myName, myPhotoFileName: myPhotoFileName,
            myVoiceEmbedding: myVoiceEmbedding,
            customVocabulary: nil, vocabularyEntries: vocabularyEntries,
            asrEngine: asrEngine,
            vocabularySourceURL: vocabularySourceURL.isEmpty ? nil : vocabularySourceURL,
            vocabularyHeaders: nil,  // Keychain-only since build 6
            vocabularyLastSync: vocabularyLastSync,
            autoSummarize: autoSummarize,
            syncToken: nil,          // Keychain-only since build 6
            syncHost: syncHost.isEmpty ? nil : syncHost,
            autoPushToMac: autoPushToMac
        )
        do {
            let data = try JSONEncoder().encode(persisted)
            try data.write(to: Self.storeURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            saveError = nil
        } catch {
            saveError = "Could not save the session library: \(error.localizedDescription). Free up storage and try again."
        }
    }
```

- [ ] **Step 3: Surface the warnings in `App/Sources/Views/PeopleListView.swift`.** After the `.alert("Add Person", ...)` modifier chain (before the `// Siri / Action button` comment), add:

```swift
            .alert("Library Problem", isPresented: Binding(
                get: { store.startupWarning != nil || store.saveError != nil },
                set: { if !$0 { store.startupWarning = nil; store.saveError = nil } }
            )) {
                Button("OK") { store.startupWarning = nil; store.saveError = nil }
            } message: {
                Text(store.startupWarning ?? store.saveError ?? "")
            }
```

- [ ] **Step 4: Compile check** — same as Task 5 Step 4 (xcodebuild if available).

- [ ] **Step 5: Commit**

```bash
git add App/Sources/KeychainStore.swift App/Sources/Store.swift App/Sources/Views/PeopleListView.swift
git commit -m "Harden persistence: quarantine corrupt library, Keychain secrets, file protection

- A corrupt store.json previously loaded as an empty library and the next
  save() overwrote everything (sessions, enrollment, vocabulary) silently.
  Unreadable files are now quarantined and the user is told.
- save() failures (storage full) surface in the UI instead of vanishing.
- The Mac-sync pairing token and vocabulary auth headers move from
  plaintext store.json to the Keychain (device-only, after-first-unlock),
  with one-way migration from existing installs.
- Documents/audio/photos get completeUnlessOpen data protection.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: Small correctness fixes (re-transcribe, duplicate model loads, CLI, https-only vocab)

**Files:**
- Modify: `App/Sources/SessionProcessing.swift:33` (re-transcribe guard)
- Modify: `App/Sources/PipelineService.swift` (reentrancy)
- Modify: `App/Sources/SummaryService.swift` (reentrancy)
- Modify: `App/Sources/VocabularySync.swift:22-26` (https only)
- Modify: `Sources/LuxiconCLI/LuxiconCLI.swift` (pass vocabulary; bounds-check option values)

**Interfaces:**
- Consumes: `MeetingPipeline.process(audio:title:date:enrollments:vocabulary:...)` — `vocabulary:` param exists with a default (verified at `MeetingPipeline.swift:128`).
- Produces: no signature changes visible to other tasks.

- [ ] **Step 1: Re-transcribe.** In `App/Sources/SessionProcessing.swift`, replace the guard in `startProcessing`:

```swift
        // .recorded/.failed start normally; .ready allows Re-transcribe. Only
        // a session already being processed is refused.
        guard session.status != .processing, processing.tasks[session.id] == nil else { return }
```

- [ ] **Step 2: PipelineService reentrancy.** Actor reentrancy let two callers both see `pipeline == nil` and download/load twice (~700 MB + jetsam risk). `MeetingPipeline` is not Sendable, so a shared `Task` handle won't compile — use an in-flight flag the actor re-checks. Replace `ensureLoaded` in `App/Sources/PipelineService.swift`:

```swift
    private var isLoading = false

    func ensureLoaded(
        engine: ASREngine = .parakeet,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> MeetingPipeline {
        // Actor reentrancy: a second caller arriving mid-load would also see
        // pipeline == nil and start a duplicate ~700 MB download. Park until
        // the in-flight load settles, then re-check.
        while isLoading {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if let pipeline, loadedEngine == engine { return pipeline }
        isLoading = true
        defer { isLoading = false }
        pipeline = nil  // release the old engine's memory before loading anew
        let loaded = try await MeetingPipeline.load(engine: engine, progress: progress)
        pipeline = loaded
        loadedEngine = engine
        return loaded
    }
```

- [ ] **Step 3: SummaryService reentrancy.** Same pattern in `App/Sources/SummaryService.swift` — replace the body of `summarize` up to the `progress("Summarizing…")` line:

```swift
    private var isLoading = false

    func summarize(
        _ transcript: MeetingTranscript,
        progress: @Sendable @escaping (String) -> Void
    ) async throws -> SessionSummary {
        while isLoading {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if summarizer == nil {
            isLoading = true
            defer { isLoading = false }
            summarizer = try await MeetingSummarizer.load { fraction, stage in
                progress("\(stage) \(Int(fraction * 100))%")
            }
        }
        progress("Summarizing…")
```

(rest of the function unchanged).

- [ ] **Step 4: https-only vocabulary sync.** In `App/Sources/VocabularySync.swift`, replace the scheme guard:

```swift
        guard let url = URL(string: urlString), url.scheme?.lowercased() == "https" else {
            vocabularySyncError = "Not a valid https URL. (Plain http would expose your auth headers.)"
            return
        }
```

- [ ] **Step 5: CLI fixes.** In `Sources/LuxiconCLI/LuxiconCLI.swift`:

(a) Inside `run()`, before the `while i < args.count` loop, add a bounds-checked accessor:

```swift
        func value(after flag: String, at i: Int) throws -> String {
            guard args.indices.contains(i + 1) else {
                throw ValidationError("\(flag) expects a value")
            }
            return args[i + 1]
        }
```

(b) Replace every raw `args[i + 1]` in the option loop with `try value(after: <flag>, at: i)` — cases `--enroll`, `--out`, `--title`, `--vocab`, `--vocab-file`, `--engine`.

(c) Pass the parsed vocabulary (it was parsed and silently dropped). In the `pipeline.process(` call add the argument after `enrollments: enrollments`:

```swift
            enrollments: enrollments,
            vocabulary: vocabulary
```

- [ ] **Step 6: Build + spot check.** `swift build && swift test 2>&1 | tail -3` → pass. Run `.build/debug/luxicon-cli x.wav --out` (missing value) → expect `error: --out expects a value`, exit 1, no crash.

- [ ] **Step 7: Commit**

```bash
git add App/Sources/SessionProcessing.swift App/Sources/PipelineService.swift App/Sources/SummaryService.swift App/Sources/VocabularySync.swift Sources/LuxiconCLI/LuxiconCLI.swift
git commit -m "Fix re-transcribe, duplicate model loads, CLI vocab, https-only vocab sync

- Re-transcribe was a silent no-op: the status guard rejected .ready.
- Actor reentrancy could start duplicate ~700 MB / ~404 MB model loads.
- luxicon-cli parsed --vocab/--vocab-file and then never passed the result
  to the pipeline; trailing flags crashed with index-out-of-range.
- Vocabulary sync no longer accepts http:// URLs (auth headers in
  cleartext); ATS already blocked them at runtime.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: README rewrite (privacy truthfulness, sync docs, build requirements)

**Files:**
- Modify: `README.md`

**Interfaces:** none (prose). Facts to encode, verified against code: 6 MCP tools incl. `get_summary`; `luxicon-mcp listen` + `.sync-token`; app compile requires Xcode 26 (`BGContinuedProcessingTask` in ContinuedProcessing.swift is an iOS 26 SDK symbol; runs on iOS 18+); package/CLI build with Xcode 16+; downloads: ~700 MB transcription + ~404 MB summarizer + caption model (+ optional Qwen3-ASR ~400 MB) — "up to ~1.2 GB across features"; sync is opt-in TLS-PSK on the LAN.

- [ ] **Step 1: Apply these edits to `README.md`:**

(a) Line 53 build requirements — replace `Requires Xcode 16+, iOS 18+ device (A13 or later recommended).` with:

```markdown
Requires **Xcode 26+** to build (the background-processing code uses iOS 26
SDK symbols, runtime-gated to run fine on iOS 18+ devices). Target device:
iOS 18+, A13 or later recommended. The Swift package (CLI, MCP server)
builds with Xcode 16+.
```

(b) Replace the whole `## Privacy posture` section with:

```markdown
## Privacy posture

- Audio, transcripts, and voice fingerprints are stored in the app's Documents
  container on-device. They are included in your normal iPhone backup
  (encrypted by Apple; end-to-end if you use Advanced Data Protection) — so a
  restored phone keeps your library.
- Out of the box, the only network traffic is the model download from
  Hugging Face (no user data attached).
- Two **opt-in** features create additional traffic, both under your control:
  - **Mac sync** — when you pair a Mac, transcripts and summaries you push
    (or all new ones, if you enable auto-push) travel over your local network
    to that Mac, encrypted with a key derived from the pairing token. Nothing
    goes to the internet. See [docs/sync.md](docs/sync.md).
  - **Vocabulary URL sync** — when you configure a vocabulary URL, the app
    fetches it (https only) when opened.
- Export is explicit: you choose what leaves the device, and when.
```

(c) Replace the two-line claim at lines 3-8: change `get a speaker-labeled transcript that never leaves the device` → `get a speaker-labeled transcript that stays on your devices`, and `No cloud APIs. No per-minute pricing. No audio leaving the phone.` stays (audio truly never leaves).

(d) Update `## Structure` block to:

```markdown
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
```
```

(e) MCP section: replace the tool list line with:

```markdown
Tools: `list_people`, `list_sessions`, `get_transcript`, `get_summary`,
`search_transcripts`, `talk_time_trends`. The library is re-scanned on every
call, so newly pushed or AirDropped exports appear immediately.
```

and after that section add:

```markdown
### Mac sync (push from the phone)

Instead of AirDropping exports, run the listener and pair the phone once:

```bash
.build/release/luxicon-mcp listen          # prints a pairing token
# iPhone: My Voice → Mac sync → enter the token
```

Transcripts you push (or every new one, with auto-push) land in `~/Luxicon`
as JSON, ready for the MCP server. Connections are TLS-PSK on your local
network; see [docs/sync.md](docs/sync.md) for pairing details and
troubleshooting.
```

(f) CLI section: add the missing flags after the existing example:

```markdown
Other flags: `--vocab "Choreo, OKR"` / `--vocab-file terms.json` ground
transcription in your jargon, `--engine qwen3` switches the ASR engine, and
`luxicon-cli push export.json --token <token> [--host <mac-ip>]` exercises
the same sync path the app uses.
```

(g) Model size: line 29 `Models (~700 MB) download from Hugging Face on first transcription and are cached on-device.` → 

```markdown
Models download from Hugging Face on first use and are cached on-device:
~700 MB for transcription + diarization, ~400 MB more for on-device
summaries, plus a small live-caption model (~1.2 GB total if you use
everything).
```

- [ ] **Step 2: Verify claims against code** — `grep -c "server.addTool\|Tool(name:" Sources/LuxiconMCP/LuxiconMCP.swift` style spot-checks: confirm 6 tools listed match `LuxiconMCP.swift`, confirm `listen` subcommand exists there. 

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "README: truthful privacy posture, Mac sync docs, correct build requirements

The privacy section claimed the model download was the only network
traffic — false since Mac sync and vocabulary URL sync shipped. Both are
now disclosed as the opt-in features they are. Also: Xcode 26 build
requirement (iOS 26 SDK symbols), complete MCP tool list (get_summary),
sync + CLI usage, realistic model download sizes.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9: Sync guide, privacy policy, SECURITY.md, CHANGELOG, App Store copy

**Files:**
- Create: `docs/sync.md`
- Create: `docs/privacy-policy.md`
- Create: `SECURITY.md`
- Create: `CHANGELOG.md`
- Modify: `marketing/app-store.md`

- [ ] **Step 1: Create `docs/sync.md`:**

```markdown
# Mac sync — pairing and troubleshooting

Luxicon can push finished transcripts (and summaries) from the iPhone to a
Mac over your local network, so the MCP server can serve them to Claude
without AirDrop round-trips.

## How it works

- The Mac runs `luxicon-mcp listen`, which advertises `_luxicon._tcp` via
  Bonjour on port 51234 and prints a **pairing token** (also stored beside
  the library at `.sync-token`, chmod 600).
- The phone connects with TLS-PSK: both sides derive the key from the
  pairing token (SHA-256), so nothing on the wire is readable — and nothing
  can be pushed — without the token. Traffic never leaves your LAN.
- Pushes are one file per connection; re-pushing a session after its summary
  lands simply overwrites the same file (idempotent).

## Pairing

1. On the Mac: `swift build -c release && .build/release/luxicon-mcp listen`
2. On the iPhone: **My Voice → Mac sync**, enter the printed token.
3. Optional: toggle **Push automatically after each 1-on-1**, or use
   **Push All to Mac** from a person's share menu.

## When the Mac isn't found

Enterprise Wi-Fi often blocks mDNS/Bonjour. The listener prints its IP
addresses at startup — enter one under **Mac address** on the phone and
Luxicon connects directly to port 51234.

Other checks:

- iOS will ask for **Local Network** permission on the first push; if you
  declined, re-enable it in Settings → Privacy & Security → Local Network →
  Luxicon.
- Both devices must be on the same network (and not isolated by a guest
  SSID).
- A wrong token fails the TLS handshake — re-copy it from the listener
  output.

## Security notes

- The pairing token is the only credential. On the phone it is stored in
  the Keychain; on the Mac, in `.sync-token` next to the library. Delete
  that file to force a new token (re-pair the phone afterwards).
- Sessions use `TLS_PSK_WITH_AES_128_GCM_SHA256`. There is no forward
  secrecy: treat the token like a password and rotate it if a device is
  compromised.
- The listener accepts frames up to 64 MiB and only writes sanitized
  `*.json` filenames inside the library directory.
```

- [ ] **Step 2: Create `docs/privacy-policy.md`:**

```markdown
# Luxicon privacy policy

*Effective 2026-07-09.*

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

- **Speech model download** (required, first use): models are fetched from
  Hugging Face. No user data is sent — it is a file download.
- **Mac sync** (optional, off by default): if you pair a Mac, transcripts
  and summaries you choose to push travel over your local network to that
  Mac, encrypted with a key derived from your pairing token. They do not
  cross the internet.
- **Vocabulary URL sync** (optional, off by default): if you configure a
  vocabulary URL, the app fetches that file over https when opened.

That is the complete list. Without those optional features, Luxicon works
in airplane mode after the model download.

## Sharing

Nothing leaves the app unless you export or push it. What you share — and
with whom — is up to you.

## Contact

Questions: open an issue at https://github.com/DavidsonCollege/luxicon or
email jdmills@davidson.edu.
```

- [ ] **Step 3: Create `SECURITY.md`:**

```markdown
# Security policy

Luxicon handles sensitive workplace conversations, so we take reports
seriously.

## Reporting a vulnerability

Email **jdmills@davidson.edu** or use GitHub's private vulnerability
reporting on this repository. Please include reproduction steps. You should
hear back within five business days.

Please do not open public issues for exploitable vulnerabilities before
we've had a chance to ship a fix.

## Scope notes

- The iOS app opens no listening ports; the LAN sync channel is
  authenticated and encrypted with TLS-PSK derived from the pairing token.
- `luxicon-mcp listen` is intended for trusted local networks. The pairing
  token (`.sync-token`, and the phone's Keychain) is the only credential —
  treat it like a password.
```

- [ ] **Step 4: Create `CHANGELOG.md`:**

```markdown
# Changelog

## 1.0 (build 6) — unreleased

Pre-release hardening pass (QA audit 2026-07-09):

- Mac sync now works on device: local-network permission keys were missing,
  and an unreachable Mac hung pushes forever instead of timing out.
- A phone call mid-recording no longer silently ends capture; recording
  resumes after the interruption and the UI says so.
- Microphone-permission denial is handled instead of crashing.
- A corrupt session library is quarantined instead of being silently
  overwritten; save failures are surfaced.
- The Mac-sync pairing token and vocabulary auth headers moved to the
  Keychain; library files get stronger data protection.
- Long recordings no longer hold the whole session in memory.
- Re-transcribe works; duplicate model downloads prevented; CLI --vocab is
  honored; vocabulary sync is https-only; sync listener caps frame sizes.
- Widget extension version now matches the app (App Store upload fix).
- README/App Store copy now disclose the opt-in sync features; added
  privacy policy, sync guide, SECURITY.md.

## 1.0 (builds 1–5)

Initial development: on-device diarized transcription, speaker enrollment,
summaries, live captions, vocabulary, Siri/App Intents, widgets, MCP
server, Bonjour/LAN Mac sync.
```

- [ ] **Step 5: Update `marketing/app-store.md`:**

(a) Replace the `PRIVATE BY ARCHITECTURE` description paragraph with:

```markdown
PRIVATE BY ARCHITECTURE
All speech processing runs on the Apple Neural Engine and GPU in your
iPhone. Aside from a one-time download of the speech models, Luxicon makes
no network connections unless you turn them on: pair a Mac and it can send
transcripts to that Mac over your own Wi-Fi (encrypted, never the
internet); point it at a vocabulary file URL and it will fetch that file.
Otherwise it works in airplane mode. Recordings, transcripts, and voice
fingerprints stay in the app's private on-device storage and your own
iPhone backup.
```

(b) Add a description feature block after `HANDS-FREE START` (Mac sync deserves marketing, not just disclosure):

```markdown
SEND TRANSCRIPTS TO YOUR MAC
Pair once with the bundled Mac listener and every finished 1-on-1 can land
on your Mac automatically — over your local network, encrypted end to end,
ready for Claude or any MCP-capable assistant to search and summarize. No
cloud in between.
```

(c) Replace the `## App Privacy (nutrition label)` bullets with:

```markdown
- Data collection: **Data Not Collected** — the app has no analytics, no
  accounts, and no third-party services; the developer receives nothing.
- Network use: the Hugging Face model download (no user data), plus two
  opt-in, user-configured connections: Mac sync on the local network and
  vocabulary fetches from a user-supplied https URL.
- Microphone: used to record meetings the user explicitly starts; audio is
  processed and stored on-device only.
```

(d) After the `## Support URL` section add:

```markdown
## Privacy Policy URL
https://github.com/DavidsonCollege/luxicon/blob/main/docs/privacy-policy.md
```

- [ ] **Step 6: Commit**

```bash
git add docs/sync.md docs/privacy-policy.md SECURITY.md CHANGELOG.md marketing/app-store.md
git commit -m "Add privacy policy, sync guide, SECURITY.md, changelog; fix App Store privacy copy

The listing claimed 'no network requests except the model download', which
Mac sync and vocabulary URL sync made false. The copy now discloses both as
opt-in features (and markets Mac sync properly). Privacy policy URL added —
App Store Connect requires one.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Final verification (after all tasks)

- [ ] `swift build && swift test` — clean.
- [ ] `git log --oneline -9` — nine commits landed.
- [ ] If xcodegen + iOS SDK available: `cd App && xcodegen generate && xcodebuild -project Luxicon.xcodeproj -scheme Luxicon -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`.
- [ ] `grep -rn "only network traffic" README.md marketing/` → no stale claims.
- [ ] Items that still need a physical device to verify (list for the user): local-network permission prompt on first push, interruption resume during a real phone call, mic-denied first-run flow, App Store Connect upload validation of build 6.
