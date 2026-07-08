import Foundation
import SitdownKit

/// Owns the (non-Sendable) models and serializes all inference.
/// Models load lazily on first use and stay resident (~700 MB download on first run).
actor PipelineService {
    static let shared = PipelineService()

    private var pipeline: MeetingPipeline?

    func ensureLoaded(progress: (@Sendable (Double, String) -> Void)? = nil) async throws -> MeetingPipeline {
        if let pipeline { return pipeline }
        let loaded = try await MeetingPipeline.load(progress: progress)
        pipeline = loaded
        return loaded
    }

    /// Diarize + transcribe a recording.
    func process(
        audio: [Float],
        title: String,
        date: Date,
        enrollments: [VoiceEnrollment],
        progress: @Sendable @escaping (Double, String) -> Void
    ) async throws -> MeetingTranscript {
        let pipeline = try await ensureLoaded { p, stage in
            progress(p * 0.2, stage)
        }
        return try pipeline.process(
            audio: audio, title: title, date: date, enrollments: enrollments
        ) { p, stage in
            progress(0.2 + p * 0.8, stage)
        }
    }

    /// Extract a voice embedding from an enrollment recording.
    func embedVoice(audio: [Float]) async throws -> [Float] {
        let pipeline = try await ensureLoaded()
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
