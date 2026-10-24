import Foundation
import LuxiconKit
#if os(macOS)
import os
#endif

/// Owns the (non-Sendable) models and serializes all inference.
/// Models load lazily on first use and stay resident (~700 MB download on first run).
actor PipelineService {
    static let shared = PipelineService()

    private var pipeline: MeetingPipeline?
    private var loadedEngine: ASREngine?
    private var loadedDiarization: DiarizationMethod?
    private var isLoading = false

    func ensureLoaded(
        engine: ASREngine,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> MeetingPipeline {
        // Actor reentrancy: a second caller arriving mid-load would also see
        // pipeline == nil and start a duplicate ~700 MB download. Park until
        // the in-flight load settles, then re-check.
        while isLoading {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        // Never load an engine this platform can't run (a persisted `cohere`
        // choice read on iOS) — fall back to the automatic default instead.
        let engine = ASREngine.resolved(engine)
        let diarization = Self.currentDiarizationMethod()
        if let pipeline, loadedEngine == engine, loadedDiarization == diarization { return pipeline }
        isLoading = true
        defer { isLoading = false }
        pipeline = nil  // release the old engine's memory before loading anew
        let loaded: MeetingPipeline
        #if os(macOS)
        Self.log.notice("Loading models: engine=\(engine.rawValue, privacy: .public), diarization=\(String(describing: diarization), privacy: .public)")
        let progress = Self.loggingStageChanges(progress)
        #endif
        do {
            #if os(macOS) && DEBUG
            if engine == .cohere, DebugLaunchOptions.consumeSimulatedModelDownloadFailure() {
                // What URLSession surfaces with no network.
                throw URLError(.notConnectedToInternet, userInfo: [
                    NSLocalizedDescriptionKey: "The Internet connection appears to be offline.",
                ])
            }
            #endif
            loaded = try await MeetingPipeline.load(engine: engine, diarization: diarization, progress: progress)
        } catch where engine == .cohere && !(error is CancellationError) && !Task.isCancelled {
            // The 1.6 GB first-use download is the likeliest failure (offline,
            // disk full). Say what failed and how to recover rather than a
            // raw error dump; the session stays .failed with Retry.
            throw CohereLoadError(underlying: error)
        } catch where engine == .appleSpeech && !(error is CancellationError) && !Task.isCancelled {
            // System transcriber unavailable (locale/asset) — never block a
            // meeting on it. Cache under the requested key so we don't retry
            // (and re-fail) the download every session this run. Cancellation
            // propagates instead of triggering fallback — the caller is going
            // away, not failing, and we must not silently downgrade the
            // cached engine for the rest of the app run.
            progress?(0, "System transcription unavailable — using built-in engine")
            loaded = try await MeetingPipeline.load(engine: .parakeet, diarization: diarization, progress: progress)
        }
        pipeline = loaded
        loadedEngine = engine
        loadedDiarization = diarization
        return loaded
    }

    #if os(macOS)
    private static let log = Logger(subsystem: "edu.davidson.luxicon.mac", category: "pipeline")

    /// DEBUG: echo each distinct load stage to stderr, so a stuck or
    /// misleading stage ("… 100%" while weights load) shows in a test run.
    private static func loggingStageChanges(
        _ progress: (@Sendable (Double, String) -> Void)?
    ) -> (@Sendable (Double, String) -> Void)? {
        #if DEBUG
        let last = OSAllocatedUnfairLock(initialState: "")
        return { fraction, stage in
            let changed = last.withLock { previous in
                defer { previous = stage }
                return previous != stage
            }
            if changed {
                FileHandle.standardError.write(Data("[load stage] \(stage)\n".utf8))
            }
            progress?(fraction, stage)
        }
        #else
        return progress
        #endif
    }
    #endif

    /// Diarization method for new loads. iOS is always `.default` (classic).
    /// On macOS a hidden `UserDefaults` key opts into v2 for validation:
    /// `diarizationMethod` = "classic" | "v2", optional `diarizationThreshold`
    /// (Double). Unknown values fall back to the default.
    static func currentDiarizationMethod() -> DiarizationMethod {
        #if os(macOS)
        let defaults = UserDefaults.standard
        guard let name = defaults.string(forKey: "diarizationMethod") else { return .default }
        let threshold = defaults.object(forKey: "diarizationThreshold") != nil
            ? Float(defaults.double(forKey: "diarizationThreshold")) : nil
        return DiarizationMethod(cliValue: name, threshold: threshold) ?? .default
        #else
        return .default
        #endif
    }

    /// Diarize + transcribe a recording.
    func process(
        audio: [Float],
        title: String,
        date: Date,
        enrollments: [VoiceEnrollment],
        vocabulary: [VocabularyEntry],
        engine: ASREngine,
        progress: @Sendable @escaping (Double, String) -> Void
    ) async throws -> MeetingTranscript {
        let pipeline = try await ensureLoaded(engine: engine) { p, stage in
            progress(p * 0.2, stage)
        }
        return try pipeline.process(
            audio: audio, title: title, date: date,
            enrollments: enrollments, vocabulary: vocabulary
        ) { p, stage in
            progress(0.2 + p * 0.8, stage)
        }
    }

    /// Extract a voice embedding from an enrollment recording. Embedding only
    /// uses the diarizer, so any loaded pipeline serves; avoid dumping a
    /// loaded pipeline just to satisfy an engine default.
    func embedVoice(audio: [Float]) async throws -> [Float] {
        let pipeline = try await ensureLoaded(engine: ASREngine.resolved(loadedEngine))
        return pipeline.embedVoice(audio: audio)
    }
}

/// Loading the models for Cohere Transcribe failed — most likely its 1.6 GB
/// first-use download (offline, disk full). Readable as-is: a failed
/// session shows `"\(error)"`, so `description` carries the message.
struct CohereLoadError: Error, LocalizedError, CustomStringConvertible {
    let underlying: Error

    var errorDescription: String? {
        var reason = underlying.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = reason.last, !".!?)".contains(last) { reason += "." }
        return "Couldn't download or load the Cohere Transcribe model. \(reason) "
            + "The first use downloads 1.6 GB from Hugging Face — check your internet "
            + "connection and free disk space, then Retry, or choose another engine "
            + "in Settings."
    }
    var description: String { errorDescription ?? "Couldn't load the Cohere Transcribe model." }
}

extension MeetingTranscript {
    /// 1-on-1 inference: when the user's enrolled voice matched one of two
    /// speakers, the remaining unnamed speaker must be the other participant.
    mutating func nameRemainingSpeaker(_ name: String) {
        let unnamed = speakers.filter { $0.speakerName == nil }
        guard speakers.count == 2, unnamed.count == 1,
              let speakerId = unnamed.first?.speakerId else { return }
        setName(name, forSpeaker: speakerId)
    }
}
