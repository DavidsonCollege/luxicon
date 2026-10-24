import Foundation
import LuxiconKit

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
        let diarization = Self.currentDiarizationMethod()
        if let pipeline, loadedEngine == engine, loadedDiarization == diarization { return pipeline }
        isLoading = true
        defer { isLoading = false }
        pipeline = nil  // release the old engine's memory before loading anew
        let loaded: MeetingPipeline
        do {
            loaded = try await MeetingPipeline.load(engine: engine, diarization: diarization, progress: progress)
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
        let pipeline = try await ensureLoaded(engine: loadedEngine ?? .resolvedDefault())
        return pipeline.embedVoice(audio: audio)
    }
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
