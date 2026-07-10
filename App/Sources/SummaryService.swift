import Foundation
import LuxiconKit

/// Owns the (non-Sendable) summarization LLM and serializes summary requests.
/// Loads lazily on first use (~404 MB one-time download) and stays resident.
actor SummaryService {
    static let shared = SummaryService()

    private var summarizer: MeetingSummarizer?
    private var isLoading = false

    func summarize(
        _ transcript: MeetingTranscript,
        context: [SummaryParticipant],
        progress: @Sendable @escaping (String) -> Void
    ) async throws -> (listLabel: String, summary: SessionSummary) {
        // Actor reentrancy: without the gate, two sessions summarizing at once
        // would both see nil and download/load the model twice.
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
        try Task.checkCancellation()
        let result = try summarizer!.summarize(transcript, context: context)
        return (
            listLabel: result.headline,
            summary: SessionSummary(overview: result.overview, generatedAt: Date())
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

        // Participant context is deliberately NOT fed to the summarizer: the
        // on-device model confabulates the summary from prose background rather
        // than grounding in the transcript (verified with luxicon-cli
        // summarize). The context/glossary plumbing in LuxiconKit is kept for a
        // future, more capable model. Summaries are transcript-only for now.
        let context: [SummaryParticipant] = []

        let task = Task {
            do {
                let result = try await SummaryService.shared.summarize(transcript, context: context) { stage in
                    Task { @MainActor in
                        self.processing.summarizing[sessionId] = stage
                    }
                }
                if var s = self.sessions.first(where: { $0.id == sessionId }) {
                    s.summary = result.summary
                    s.listLabel = result.listLabel
                    // The Mac copy (if any) predates this summary: show
                    // "pending" rather than a green mark over stale content.
                    s.lastPushDate = nil
                    s.lastPushError = nil
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
