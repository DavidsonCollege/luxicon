import Foundation
import LuxiconKit

/// Owns the (non-Sendable) summarization LLM and serializes summary requests.
/// Loads lazily on first use and stays resident. Backend: Gemma 4 E2B —
/// chosen over Qwen3.5 0.8B/2B after harness A/B (grounded summaries even
/// with participant context, topic-style labels; see luxicon-cli summarize).
actor SummaryService {
    static let shared = SummaryService()

    static let backend = MeetingSummarizer.Backend.gemma4
    /// Shown in the enable flow; the real download is whatever the repo holds.
    static let approximateDownload = "2.5 GB"

    private var summarizer: MeetingSummarizer?
    private var isLoading = false

    /// Download (if needed) and load the model, reporting progress. Used by
    /// both the explicit enable flow and lazy loading before a summary.
    func loadModel(progress: @Sendable @escaping (String) -> Void) async throws {
        // Actor reentrancy: without the gate, two callers would both see nil
        // and download/load the model twice.
        while isLoading {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if summarizer == nil {
            isLoading = true
            defer { isLoading = false }
            summarizer = try await MeetingSummarizer.load(backend: Self.backend) { fraction, stage in
                progress("\(stage) \(Int(fraction * 100))%")
            }
        }
    }

    /// Drop the resident model so its cache directory can be deleted.
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
        let result = try await summarizer!.summarize(transcript, context: context)
        return (
            listLabel: result.headline,
            summary: SessionSummary(overview: result.overview, generatedAt: Date())
        )
    }
}

extension Store {
    /// Whether the summarization model is already on disk.
    var summaryModelDownloaded: Bool {
        MeetingSummarizer.isModelDownloaded(SummaryService.backend)
    }

    /// Free space on the device volume, for the enable-flow disclosure.
    static func availableDiskSpace() -> Int64? {
        let values = try? Store.documentsURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Opt in: flip the switch and download the model with visible progress.
    /// On failure the switch flips back — the feature is never "on" without
    /// a working model.
    func enableAISummaries() {
        guard !aiSummariesEnabled || !summaryModelDownloaded else { return }
        aiSummariesEnabled = true
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
                self.summaryModelError = "Model download failed: \(error.localizedDescription)"
                self.aiSummariesEnabled = false
                self.save()
            }
        }
    }

    /// Opt out. `deleteModel` also removes the weights from disk to reclaim
    /// the space; existing summaries on sessions are kept and stay readable.
    func disableAISummaries(deleteModel: Bool) {
        aiSummariesEnabled = false
        summaryModelDownloadStage = nil
        summaryModelError = nil
        save()
        if deleteModel {
            Task {
                await SummaryService.shared.unloadModel()
                if let dir = try? MeetingSummarizer.modelCacheDirectory(for: SummaryService.backend) {
                    try? FileManager.default.removeItem(at: dir)
                }
            }
        }
    }

    /// One-time cleanup: builds 1-9 used the Qwen3.5-0.8B model; those weights
    /// are dead space now that the app is Gemma-only. Deletes only that model's
    /// directory — ASR/diarization caches are untouched.
    func removeLegacySummaryModel() {
        guard let dir = try? MeetingSummarizer.modelCacheDirectory(for: .qwen35),
              FileManager.default.fileExists(atPath: dir.path) else { return }
        try? FileManager.default.removeItem(at: dir)
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

        // Participant context adds nuance the transcript alone can't carry
        // (roles, running themes). Safe with the Gemma backend: harness A/B
        // showed it stays grounded with context, where the old 0.8B model
        // confabulated summaries out of it.
        var context = [SummaryParticipant(name: myName, context: myContext)]
        if let person = person(id: session.personId) {
            context.append(SummaryParticipant(name: person.name, context: person.context ?? ""))
        }

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
