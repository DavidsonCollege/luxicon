import Foundation
import AVFoundation
import LuxiconKit
#if canImport(UIKit)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

enum RecorderError: LocalizedError {
    case microphoneAccessDenied
    case microphoneUnavailable

    var errorDescription: String? {
        switch self {
        case .microphoneAccessDenied:
            #if os(macOS)
            return "Microphone access is off for Luxicon. Turn it on in System Settings → Privacy & Security → Microphone."
            #else
            return "Microphone access is off for Luxicon. Turn it on in Settings → Privacy & Security → Microphone."
            #endif
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
/// so the UI can say so. CallKit calls (Zoom Phone, etc.) often never deliver
/// the `.ended` event — or deliver it while the other app still holds the mic —
/// so the recorder also retries with backoff, retries when the app becomes
/// active again, and offers `resumeFromInterruption()` for a manual escape
/// hatch. Write failures (disk full) surface via `runtimeError` instead of
/// being silently swallowed.
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
    #if os(macOS)
    /// Registered on `NSWorkspace.shared.notificationCenter`, not the default
    /// center, so they're tracked (and removed) separately.
    private var workspaceObservers: [NSObjectProtocol] = []

    /// Called on the main thread when the Mac is about to sleep while a
    /// recording is in progress (including off the record). Sleep stops the
    /// audio hardware, so the record window stops and saves here rather than
    /// leaving a recording that silently stopped capturing. Set before `start`.
    var onSystemSleep: (@MainActor () -> Void)?
    #endif
    #if DEBUG
    /// DEBUG-only: when set before `start`, these 16 kHz samples are fed
    /// (looped, in real time) through the normal write path instead of the
    /// microphone, so the record flow can be exercised without mic access.
    var simulatedInput: [Float]?
    private var simulatedTimer: DispatchSourceTimer?
    #if os(macOS)
    /// The device a simulated recording "captures from" (nil: the default).
    private var simulatedInputDeviceID: AudioDeviceID?
    #endif
    #endif
    private(set) var isRecording = false
    /// True while another audio session (phone call, Siri) holds the mic.
    private(set) var isInterrupted = false
    /// True while the user is "off the record". Capture is fully stopped and,
    /// unlike `isInterrupted`, it NEVER auto-resumes — only `resume()` restarts
    /// it. Confined to the main thread (set by `pause`/`resume`, read by the UI),
    /// like `isInterrupted`.
    private(set) var isPaused = false

    /// Backoff schedule for re-trying capture after a failed interruption
    /// recovery (the interrupting app can take a beat to release the mic).
    private static let resumeRetryDelays: [TimeInterval] = [1, 2, 4]
    /// Next index into `resumeRetryDelays`; main-thread confined.
    private var resumeRetryAttempt = 0
    /// Invalidates in-flight retry timers when bumped (stop, pause, a new
    /// interruption, or a successful resume); main-thread confined.
    private var resumeRetryGeneration = 0

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

        try prepareWriter(for: fileURL)
        try startEngine()
        isRecording = true
        isInterrupted = false
        installObservers()
    }

    /// Fresh tally, buffer, and (for a file-backed recording) writer.
    private func prepareWriter(for fileURL: URL?) throws {
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
    }

    #if os(macOS)
    /// Start a file-backed recording already off the record (the mic was
    /// muted when it began): the file exists and the recording can be
    /// stopped and saved as usual, but nothing is captured until `resume()`.
    func startOffRecord(writingTo fileURL: URL) throws {
        guard !isRecording else { return }
        try prepareWriter(for: fileURL)
        isRecording = true
        isInterrupted = false
        isPaused = true
        installObservers()
    }

    /// Capture from `id` instead of the current input device. Mid-recording
    /// the switch is seamless — the tap is rewired with the new device's
    /// format, and the same file, tally, and session carry on. Off the
    /// record (or before `start`) it takes effect when capture next starts.
    /// Throws only if Core Audio refuses the device; a failed restart is
    /// reported via `runtimeError` and retried like any lost capture.
    func setInputDevice(_ id: AudioDeviceID) throws {
        // Capture should be flowing (not stopped, not off the record); it may
        // already have died with the old device, which the restart recovers.
        let shouldCapture = isRecording && !isPaused
        if shouldCapture && isCapturing { stopEngine() }
        #if DEBUG
        if simulatedInput != nil {
            simulatedInputDeviceID = id
            if shouldCapture { resumeCapture() }
            return
        }
        #endif
        guard let unit = engine.inputNode.audioUnit else {
            if shouldCapture { resumeCapture() }
            throw RecorderError.microphoneUnavailable
        }
        var device = id
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        // Restart either way: on failure, the previous device carries on.
        // (No-op while capture is already running.)
        if shouldCapture { resumeCapture() }
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    /// The device capture is actually bound to (the input unit's current
    /// device), which needn't be the system default. Nil before `start`.
    var currentInputDeviceID: AudioDeviceID? {
        #if DEBUG
        if simulatedInput != nil { return simulatedInputDeviceID }
        #endif
        guard isRecording, let unit = engine.inputNode.audioUnit else { return nil }
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, &size) == noErr,
              device != 0 else { return nil }
        return device
    }
    #endif

    /// Stop, finalize the on-disk file (if any), and return the in-memory
    /// samples (enrollment recordings only; file-backed recordings return []).
    func stop() -> [Float] {
        guard isRecording else { return [] }
        removeObservers()
        resumeRetryGeneration += 1
        stopEngine()
        isRecording = false
        isInterrupted = false
        isPaused = false
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
                _ = try? WAVFile.repairHeader(url: fileURL, sampleRate: Self.sampleRate)
            }
        }
        writer = nil
        fileURL = nil
        return buffer
    }

    /// User-initiated "off the record": stop capturing entirely until `resume()`.
    /// Tears down the tap and stops the engine (so `consume` can't run — no
    /// samples are written, tallied, or fed to `onSamples`) and deactivates the
    /// audio session so the system microphone indicator turns off. Idempotent.
    func pause() {
        guard isRecording, !isPaused else { return }
        isPaused = true
        resumeRetryGeneration += 1
        stopEngine()
        level = 0
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// Return from "off the record" and start capturing again, rewiring the tap
    /// with the current input format (the same recovery path interruptions use).
    func resume() {
        guard isRecording, isPaused else { return }
        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
            #endif
            try startEngine()
            isPaused = false
            isInterrupted = false
            clearRuntimeError()
        } catch {
            setRuntimeError("Couldn't resume recording: \(error.localizedDescription). Stop to save what was captured.")
        }
    }

    /// Manual recovery when an interruption didn't end cleanly: CallKit calls
    /// (Zoom Phone, the Phone app) often deliver no `.ended` event, or deliver
    /// it while the other app still holds the mic. Safe to call anytime — it's
    /// a no-op while capture is healthy, stopped, or off the record.
    func resumeFromInterruption() {
        resumeCapture()
    }

    // MARK: - Engine lifecycle

    /// (Re)wire the tap and start the engine. Reads the CURRENT input format,
    /// so it is also the recovery path after route/configuration changes.
    private func startEngine() throws {
        #if DEBUG
        if let simulatedInput {
            startSimulatedCapture(simulatedInput)
            return
        }
        #endif
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

    /// Remove the tap and stop the engine (stop, off the record).
    private func stopEngine() {
        #if DEBUG
        if simulatedInput != nil {
            simulatedTimer?.cancel()
            simulatedTimer = nil
            return
        }
        #endif
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Whether audio is currently flowing into `consume`.
    private var isCapturing: Bool {
        #if DEBUG
        if simulatedInput != nil { return simulatedTimer != nil }
        #endif
        return engine.isRunning
    }

    #if DEBUG
    /// Feed `samples` in 100 ms chunks on a timer, like the engine's tap.
    private func startSimulatedCapture(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        simulatedTimer?.cancel()
        let chunkSize = Self.sampleRate / 10
        var offset = 0
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "Recorder.simulatedInput"))
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in
            var chunk: [Float] = []
            chunk.reserveCapacity(chunkSize)
            while chunk.count < chunkSize {
                let take = min(chunkSize - chunk.count, samples.count - offset)
                chunk.append(contentsOf: samples[offset..<(offset + take)])
                offset = (offset + take) % samples.count
            }
            self?.ingest(chunk)
        }
        simulatedTimer = timer
        timer.resume()
    }
    #endif

    private func resumeCapture() {
        // `!isPaused`: a phone call ending or a route change during an off-record
        // span must NOT silently restart capture — only the user's resume() does.
        guard isRecording, !isPaused, !isCapturing else { return }
        do {
            #if os(iOS)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            try startEngine()
            isInterrupted = false
            resumeRetryAttempt = 0
            resumeRetryGeneration += 1  // cancel any in-flight retry timers
            clearRuntimeError()
        } catch {
            setRuntimeError("Recording paused and could not resume: \(error.localizedDescription). Tap Resume to retry, or stop to save what was captured.")
            scheduleResumeRetry()
        }
    }

    /// A failed resume usually means the interrupting app hasn't released the
    /// mic yet — try again shortly instead of staying silent forever.
    private func scheduleResumeRetry() {
        guard resumeRetryAttempt < Self.resumeRetryDelays.count else { return }
        let delay = Self.resumeRetryDelays[resumeRetryAttempt]
        resumeRetryAttempt += 1
        let generation = resumeRetryGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.resumeRetryGeneration == generation else { return }
            self.resumeCapture()
        }
    }

    private func setRuntimeError(_ message: String) {
        lock.lock()
        if runtimeErrorStorage == nil { runtimeErrorStorage = message }
        lock.unlock()
    }

    /// Called when capture (re)starts cleanly: a stale "could not resume"
    /// message must not outlive the recovery. A still-broken writer will
    /// simply re-set its error on the next failed append.
    private func clearRuntimeError() {
        lock.lock()
        runtimeErrorStorage = nil
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
        // CallKit interruptions (Zoom Phone, the Phone app) frequently end
        // without an `.ended` notification — especially when the app was
        // suspended during the call. Returning to the app is the one signal
        // we always get, so use it to recover capture. No-op while healthy.
        installed.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.resumeCapture()
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
        #if os(macOS)
        // Sleep stops the audio hardware; let the owner stop and save first.
        workspaceObservers = [NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onSystemSleep?() }
        }]
        #endif
    }

    private func removeObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        #if os(macOS)
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers = []
        #endif
    }

    #if os(iOS)
    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        switch type {
        case .began:
            isInterrupted = true
            // Fresh interruption: previous retry timers are stale, and the
            // next `.ended` (if any) deserves a full retry budget.
            resumeRetryGeneration += 1
            resumeRetryAttempt = 0
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

        // AVAudioConverterInputBlock is imported as @Sendable, but the
        // converter invokes it synchronously and serially on this thread
        // during this single `convert` call — never concurrently, never
        // stored past it (same contract as AppleSpeechTranscriber.pcmBuffer).
        nonisolated(unsafe) var fed = false
        nonisolated(unsafe) let inputBuffer = pcmBuffer
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return inputBuffer
        }
        guard error == nil, out.frameLength > 0, let channel = out.floatChannelData?[0] else { return }

        ingest(Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength))))
    }

    /// Meter, tally, persist, and forward one converted 16 kHz chunk.
    private func ingest(_ chunk: [Float]) {
        var sumSquares: Float = 0
        for s in chunk { sumSquares += s * s }
        level = min(1, sqrt(sumSquares / Float(chunk.count)) * 6)

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
