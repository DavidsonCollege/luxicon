import Foundation
import LuxiconKit

/// Owns the (non-Sendable) summarization LLM and serializes summary requests.
/// Loads lazily on first use and stays resident until the engine changes.
/// Engines: Apple Intelligence (OS-managed, no download) or Gemma 4 E2B —
/// the MLX backend chosen over Qwen3.5 0.8B/2B after harness A/B (grounded
/// summaries even with participant context; see luxicon-cli summarize).
actor SummaryService {
    static let shared = SummaryService()

    /// Shown in the enable flow; the real download is whatever the repo holds.
    static let approximateDownload = "2.5 GB"

    private var summarizer: MeetingSummarizer?
    private var loadedBackend: MeetingSummarizer.Backend?
    private var isLoading = false

    /// Download (if needed) and load the backend, reporting progress. Used by
    /// the enable flow, engine switches, and lazy loading before a summary.
    func loadModel(
        backend: MeetingSummarizer.Backend,
        progress: @Sendable @escaping (String) -> Void
    ) async throws {
        // Actor reentrancy: without the gate, two callers would both see nil
        // and download/load the model twice.
        while isLoading {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if loadedBackend != backend { summarizer = nil }
        if summarizer == nil {
            isLoading = true
            defer { isLoading = false }
            summarizer = try await MeetingSummarizer.load(backend: backend) { fraction, stage in
                progress("\(stage) \(Int(fraction * 100))%")
            }
            loadedBackend = backend
        }
    }

    /// Drop the resident model so its cache directory can be deleted.
    func unloadModel() {
        summarizer = nil
        loadedBackend = nil
    }

    func summarize(
        _ transcript: MeetingTranscript,
        context: [SummaryParticipant],
        backend: MeetingSummarizer.Backend,
        progress: @Sendable @escaping (String) -> Void
    ) async throws -> (listLabel: String, summary: SessionSummary) {
        try await loadModel(backend: backend, progress: progress)
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
    /// Backend behind the user's engine choice (Gemma when unset, matching
    /// the pre-engine-picker builds).
    var currentSummaryBackend: MeetingSummarizer.Backend {
        (summaryEngine ?? .gemma).backend
    }

    /// Whether the current engine is ready without a download.
    var summaryModelDownloaded: Bool {
        MeetingSummarizer.isModelDownloaded(currentSummaryBackend)
    }

    /// Free space on the device volume, for the enable-flow disclosure.
    static func availableDiskSpace() -> Int64? {
        let values = try? Store.documentsURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Opt in with the chosen engine: flip the switch and get the engine
    /// working (Gemma downloads; Apple Intelligence just checks availability)
    /// with visible progress. On failure the switch flips back — the feature
    /// is never "on" without a working engine.
    func enableAISummaries(engine: SummaryEngine) {
        guard !aiSummariesEnabled || !summaryModelDownloaded else { return }
        aiSummariesEnabled = true
        summaryEngine = engine
        summaryModelError = nil
        summaryModelDownloadStage = "Preparing…"
        save()
        Task {
            do {
                try await SummaryService.shared.loadModel(backend: engine.backend) { stage in
                    Task { @MainActor in self.summaryModelDownloadStage = stage }
                }
                self.summaryModelDownloadStage = nil
            } catch {
                self.summaryModelDownloadStage = nil
                self.summaryModelError = engine == .gemma
                    ? "Model download failed: \(error.localizedDescription)"
                    : "Apple Intelligence could not start: \(error.localizedDescription)"
                self.aiSummariesEnabled = false
                self.summaryEngine = nil
                self.save()
            }
        }
    }

    /// Switch engines while enabled. Switching to Gemma may download; on
    /// failure the previous engine is restored (same flip-back philosophy as
    /// the enable flow). The old model is unloaded either way — the resident
    /// LLM holds hundreds of MB of GPU memory.
    func switchSummaryEngine(to engine: SummaryEngine) {
        guard aiSummariesEnabled, engine != summaryEngine else { return }
        let previous = summaryEngine
        summaryEngine = engine
        summaryModelError = nil
        summaryModelDownloadStage = "Preparing…"
        save()
        Task {
            do {
                await SummaryService.shared.unloadModel()
                try await SummaryService.shared.loadModel(backend: engine.backend) { stage in
                    Task { @MainActor in self.summaryModelDownloadStage = stage }
                }
                self.summaryModelDownloadStage = nil
            } catch {
                self.summaryModelDownloadStage = nil
                self.summaryModelError = "Could not switch to \(engine.displayName): \(error.localizedDescription)"
                self.summaryEngine = previous
                self.save()
            }
        }
    }

    /// Opt out. `deleteModel` also removes the Gemma weights from disk to
    /// reclaim the space (Apple Intelligence has nothing the app could
    /// delete); existing summaries on sessions are kept and stay readable.
    func disableAISummaries(deleteModel: Bool) {
        aiSummariesEnabled = false
        summaryEngine = nil
        summaryModelDownloadStage = nil
        summaryModelError = nil
        save()
        Task {
            await SummaryService.shared.unloadModel()
            if deleteModel, let dir = try? MeetingSummarizer.modelCacheDirectory(for: .gemma4) {
                try? FileManager.default.removeItem(at: dir)
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
        processing.summarizeError[sessionId] = nil

        // Participant context adds nuance the transcript alone can't carry
        // (roles, running themes). Safe with the Gemma backend: harness A/B
        // showed it stays grounded with context, where the old 0.8B model
        // confabulated summaries out of it.
        var context = [SummaryParticipant(name: myName, context: myContext)]
        if let person = person(id: session.personId) {
            context.append(SummaryParticipant(name: person.name, context: person.context ?? ""))
        }

        let backend = currentSummaryBackend
        let task = Task {
            do {
                let result = try await SummaryService.shared.summarize(
                    transcript, context: context, backend: backend
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
                // Summary button remains available.
            } catch {
                // Real failures get a visible reason next to the Generate
                // button (guardrail refusals especially must not look like
                // the app silently doing nothing).
                processing.summarizeError[sessionId] = Self.summarizeErrorMessage(error)
            }
            processing.summarizing[sessionId] = nil
            processing.tasks[sessionId] = nil
        }
        processing.tasks[sessionId] = task
    }

    /// User-facing message for a failed summary pass, with recourse.
    static func summarizeErrorMessage(_ error: Error) -> String {
        switch error as? SummaryBackendError {
        case .declined:
            return "Apple Intelligence declined to summarize this conversation. "
                + "You can try again, or switch engines in My Voice."
        case .unavailable(.notEnabled):
            return "Apple Intelligence is turned off. Turn it on in Settings, "
                + "or switch engines in My Voice."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still preparing its model. Try again shortly."
        case .unavailable:
            return "Apple Intelligence isn't available on this device. "
                + "Switch engines in My Voice."
        case .noModelDirectory, nil:
            return "Summarization failed: \(error.localizedDescription)"
        }
    }
}
