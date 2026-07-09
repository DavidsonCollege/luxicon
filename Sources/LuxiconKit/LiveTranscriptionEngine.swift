import Foundation
import ParakeetStreamingASR

/// Streaming ASR for live captions while recording (Parakeet EOU 120M, CoreML).
///
/// Best-effort preview only — the authoritative diarized transcript is still
/// produced by `MeetingPipeline` after recording ends. Push audio from a single
/// task; the class is not thread-safe.
public final class LiveTranscriptionEngine {
    public struct Update: Sendable, Equatable {
        /// Newly committed (finalized) text, if an utterance just ended.
        public var committedDelta: String?
        /// Current in-flight hypothesis for the ongoing utterance.
        public var partial: String
    }

    private let model: ParakeetStreamingASRModel
    private var session: StreamingSession?

    public init(model: ParakeetStreamingASRModel) {
        self.model = model
    }

    public static func load(
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> LiveTranscriptionEngine {
        let model = try await ParakeetStreamingASRModel.fromPretrained(progressHandler: progress)
        return LiveTranscriptionEngine(model: model)
    }

    public func startSession() throws {
        session = try model.createSession()
    }

    /// Feed 16 kHz mono samples; returns nil when nothing changed.
    public func push(_ samples: [Float]) -> Update? {
        guard let session else { return nil }
        guard let transcripts = try? session.pushAudio(samples), !transcripts.isEmpty else { return nil }
        return reduce(transcripts)
    }

    /// End the session and flush any remaining hypothesis as committed text.
    public func finish() -> Update? {
        guard let session else { return nil }
        defer { self.session = nil }
        guard let transcripts = try? session.finalize(), !transcripts.isEmpty else { return nil }
        var update = reduce(transcripts) ?? Update(partial: "")
        if !update.partial.isEmpty {
            update.committedDelta = (update.committedDelta ?? "") + update.partial
            update.partial = ""
        }
        return update
    }

    private func reduce(_ transcripts: [ParakeetStreamingASRModel.PartialTranscript]) -> Update? {
        var update = Update(partial: "")
        for t in transcripts {
            let text = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isFinal {
                if !text.isEmpty {
                    update.committedDelta = (update.committedDelta ?? "") + text + " "
                }
                update.partial = ""
            } else {
                update.partial = text
            }
        }
        return update.committedDelta == nil && update.partial.isEmpty ? nil : update
    }
}
