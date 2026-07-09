import Foundation
import LuxiconKit

/// Owns the (non-Sendable) summarization LLM and serializes summary requests.
/// Loads lazily on first use (~404 MB one-time download) and stays resident.
actor SummaryService {
    static let shared = SummaryService()

    private var summarizer: MeetingSummarizer?

    func summarize(
        _ transcript: MeetingTranscript,
        progress: @Sendable @escaping (String) -> Void
    ) async throws -> SessionSummary {
        if summarizer == nil {
            summarizer = try await MeetingSummarizer.load { fraction, stage in
                progress("\(stage) \(Int(fraction * 100))%")
            }
        }
        progress("Summarizing…")
        try Task.checkCancellation()
        let result = try summarizer!.summarize(transcript)
        return SessionSummary(
            headline: result.headline,
            overview: result.overview,
            generatedAt: Date()
        )
    }
}

extension Store {
    /// Generate (or regenerate) the summary for a transcribed session.
    /// GPU-bound like transcription: cancelled on backgrounding, retried
    /// manually or on the next transcription pass.
    func startSummarizing(_ session: SessionRecord) {
        guard session.status == .ready, let transcript = session.transcript,
              processing.summarizing[session.id] == nil else { return }
        let sessionId = session.id
        processing.summarizing[sessionId] = "Preparing…"

        let task = Task {
            do {
                let summary = try await SummaryService.shared.summarize(transcript) { stage in
                    Task { @MainActor in
                        self.processing.summarizing[sessionId] = stage
                    }
                }
                if var s = self.sessions.first(where: { $0.id == sessionId }) {
                    s.summary = summary
                    self.update(s)
                    self.autoPushIfEnabled(s)
                }
            } catch {
                // Backgrounded or failed: leave the session summary-less; the
                // Generate Summary button remains available.
            }
            processing.summarizing[sessionId] = nil
            processing.tasks[sessionId] = nil
        }
        processing.tasks[sessionId] = task
    }
}
