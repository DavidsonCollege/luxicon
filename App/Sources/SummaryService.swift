import Foundation
import LuxiconKit

/// Owns the (non-Sendable) summarizer and serializes summary requests.
/// Apple Intelligence only: the system model is OS-managed and out-of-process
/// — no download, and none of its inference memory lands on the app.
actor SummaryService {
    static let shared = SummaryService()

    private var summarizer: MeetingSummarizer?
    private var isLoading = false

    /// Attach to the system model, reporting progress. Used by the enable
    /// flow and lazy loading before a summary; throws with the availability
    /// reason when Apple Intelligence can't run here.
    func loadModel(progress: @Sendable @escaping (String) -> Void) async throws {
        // Actor reentrancy: without the gate, two callers would both see nil
        // and attach twice.
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
    }

    /// Drop the resident summarizer (e.g. when the feature is turned off).
    func unloadModel() {
        summarizer = nil
    }

    func summarize(
        _ transcript: MeetingTranscript,
        context: [SummaryParticipant],
        progress: @Sendable @escaping (String) -> Void
    ) async throws -> (listLabel: String, summary: SessionSummary) {
        try await loadModel(progress: progress)
        progress("Summarizing…")
        try Task.checkCancellation()
        // loadModel guarantees a summarizer unless the feature was switched
        // off between the await and here — treat that race as a cancellation.
        guard let summarizer else { throw CancellationError() }
        let result = try await summarizer.summarize(transcript, context: context)
        return (
            listLabel: result.headline,
            summary: SessionSummary(overview: result.overview, generatedAt: Date())
        )
    }
}

extension Store {
    /// Opt in: flip the switch and attach to Apple Intelligence with visible
    /// progress. On failure the switch flips back — the feature is never "on"
    /// without a working engine.
    func enableAISummaries() {
        guard !aiSummariesEnabled else { return }
        aiSummariesEnabled = true
        summaryEngine = .appleIntelligence
        summaryModelError = nil
        summaryModelDownloadStage = "Preparing…"
        save()
        Task {
            do {
                try await SummaryService.shared.loadModel { stage in
                    Task { @MainActor in self.summaryModelDownloadStage = stage }
                }
                self.summaryModelDownloadStage = nil
            } catch {
                self.summaryModelDownloadStage = nil
                self.summaryModelError = "Apple Intelligence could not start: \(error.localizedDescription)"
                self.aiSummariesEnabled = false
                self.summaryEngine = nil
                self.save()
            }
        }
    }

    /// Opt out. Nothing to delete — the system model is the OS's; existing
    /// summaries on sessions are kept and stay readable.
    func disableAISummaries() {
        aiSummariesEnabled = false
        summaryEngine = nil
        summaryModelDownloadStage = nil
        summaryModelError = nil
        save()
        Task { await SummaryService.shared.unloadModel() }
    }

    /// One-time cleanup: earlier builds downloaded in-process summarizer
    /// weights (Qwen3.5 through build 9, Gemma 4 through 2026-07 — up to
    /// ~2.5 GB). Dead space now that summaries use the system model; deletes
    /// only those models' directories — ASR/diarization caches are untouched.
    func removeLegacySummaryModel() {
        for dir in MeetingSummarizer.legacyModelCacheDirectories()
        where FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// Generate (or regenerate) the summary for a transcribed session.
    /// GPU-bound like transcription: cancelled on backgrounding, retried
    /// manually or on the next transcription pass.
    func startSummarizing(_ session: SessionRecord) {
        guard aiSummariesEnabled else { return }
        guard session.status == .ready, let transcript = session.transcript,
              processing.summarizing[session.id] == nil else { return }
        let sessionId = session.id
        processing.summarizing[sessionId] = "Preparing…"
        processing.summarizeError[sessionId] = nil

        // Participant context adds nuance the transcript alone can't carry
        // (roles, running themes). Guided generation keeps the system model
        // grounded: the reference block is fenced as interpretation-only.
        var context = [SummaryParticipant(name: myName, context: myContext)]
        if let person = person(id: session.personId) {
            context.append(SummaryParticipant(name: person.name, context: person.context ?? ""))
        }

        let task = Task {
            do {
                let result = try await SummaryService.shared.summarize(
                    transcript, context: context
                ) { stage in
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
            } catch is CancellationError {
                // Backgrounded: leave the session summary-less; the Generate
                // Summary button remains available. The finished transcript
                // still auto-pushes — the summary was the add-on, not the
                // payload, and the Mac must not silently miss a session.
                if let s = self.sessions.first(where: { $0.id == sessionId }) {
                    self.autoPushIfEnabled(s)
                }
            } catch {
                // Real failures get a visible reason next to the Generate
                // button (guardrail refusals especially must not look like
                // the app silently doing nothing). The transcript still
                // auto-pushes despite the failed summary.
                processing.summarizeError[sessionId] = Self.summarizeErrorMessage(error)
                if let s = self.sessions.first(where: { $0.id == sessionId }) {
                    self.autoPushIfEnabled(s)
                }
            }
            processing.summarizing[sessionId] = nil
            processing.tasks[sessionId] = nil
        }
        processing.tasks[sessionId] = task
    }

    /// User-facing message for a failed summary pass, with recourse. The
    /// fallback is always the same: export the transcript and summarize it
    /// with any AI assistant — a core design path, not a consolation prize.
    static func summarizeErrorMessage(_ error: Error) -> String {
        switch error as? SummaryBackendError {
        case .declined:
            return "Apple Intelligence declined to summarize this conversation. "
                + "You can try again, or export the transcript and summarize it "
                + "with another AI assistant."
        case .unavailable(.notEnabled):
            return "Apple Intelligence is turned off. Turn it on in "
                + "Settings → Apple Intelligence & Siri, then try again."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still preparing its model. Try again shortly."
        case .unavailable:
            return "Summaries require Apple Intelligence, which isn't available "
                + "on this device. Export the transcript to summarize it with "
                + "another AI assistant."
        case nil:
            return "Summarization failed: \(error.localizedDescription)"
        }
    }
}
