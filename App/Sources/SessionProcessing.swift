import Foundation
import LuxiconKit
#if os(iOS)
import UIKit
#endif

/// Live progress for sessions currently being processed.
@Observable @MainActor
final class ProcessingState {
    struct Info: Equatable {
        var fraction: Double
        var stage: String
    }
    var bySession: [UUID: Info] = [:]
    /// Sessions currently generating a summary (value = stage description).
    var summarizing: [UUID: String] = [:]
    /// Running task per session, so backgrounding can cancel cleanly.
    @ObservationIgnored var tasks: [UUID: Task<Void, Never>] = [:]
    /// Sessions cancelled by backgrounding, to auto-resume on foreground.
    @ObservationIgnored var interrupted: Set<UUID> = []
    /// True while the record screen is capturing audio.
    @ObservationIgnored var recordingActive = false

    func info(for id: UUID) -> Info? { bySession[id] }
}

extension Store {
    private static let processingState = ProcessingState()
    var processing: ProcessingState { Self.processingState }

    /// Kick off diarization + transcription for a recorded session.
    func startProcessing(_ session: SessionRecord) {
        guard session.status == .recorded || session.status == .failed else { return }
        var s = session
        s.status = .processing
        s.errorMessage = nil
        update(s)
        processing.bySession[s.id] = .init(fraction: 0, stage: "Preparing…")
        refreshKeepAwake()

        let sessionId = s.id
        let audioURL = audioURL(for: s)
        let enrollments = enrollments
        let vocabulary = vocabulary
        let engine = asrEngine
        let personName = person(id: s.personId)?.name

        let task = Task {
            do {
                let audio = try MeetingPipeline.loadAudio(url: audioURL)
                var transcript = try await PipelineService.shared.process(
                    audio: audio,
                    title: s.title,
                    date: s.date,
                    enrollments: enrollments,
                    vocabulary: vocabulary,
                    engine: engine
                ) { fraction, stage in
                    Task { @MainActor in
                        self.processing.bySession[sessionId] = .init(fraction: fraction, stage: stage)
                        if #available(iOS 26.0, *) {
                            ContinuedProcessing.shared.report(
                                sessionId: sessionId, fraction: fraction, stage: stage)
                        }
                    }
                }
                if let personName {
                    transcript.nameRemainingSpeaker(personName)
                }
                s.transcript = transcript
                s.status = .ready
                s.summary = nil  // stale after re-transcription
            } catch is CancellationError {
                // Backgrounded or user-cancelled: audio is safe, just not processed.
                s.status = .recorded
            } catch {
                s.status = .failed
                s.errorMessage = "\(error)"
            }
            processing.bySession[sessionId] = nil
            processing.tasks[sessionId] = nil
            if #available(iOS 26.0, *) {
                ContinuedProcessing.shared.end(sessionId: sessionId, success: s.status == .ready)
            }
            update(s)
            refreshKeepAwake()
            if s.status == .ready, self.autoSummarize {
                self.startSummarizing(s)  // auto-push fires after the summary lands
            } else if s.status == .ready {
                self.autoPushIfEnabled(s)
            }
        }
        processing.tasks[sessionId] = task

        // On devices with background GPU (iOS 26+), a continuous background
        // task lets this work survive backgrounding; on expiration, reuse the
        // backgrounding cancellation path so the session returns to .recorded
        // and auto-resumes on next foreground.
        if #available(iOS 26.0, *) {
            let title = personName.map { "Transcribing 1-on-1 with \($0)" } ?? "Transcribing 1-on-1"
            ContinuedProcessing.shared.begin(sessionId: sessionId, title: title) { [weak self] in
                guard let self else { return }
                self.processing.interrupted.insert(sessionId)
                self.processing.tasks[sessionId]?.cancel()
            }
        }
    }

    /// iOS kills processes that touch the GPU while backgrounded (MLX
    /// diarization does). Cancel gracefully and pick the work back up when the
    /// app returns to the foreground — unless a continuous background task
    /// with GPU access covers the session (iOS 26+, supported devices).
    func handleScenePhaseChange(toBackground: Bool) {
        if toBackground {
            for (id, task) in processing.tasks {
                // Sessions holding a GPU-granted continuous background task
                // (iOS 26+) keep running; the system supervises them via a
                // Live Activity and expires them if needed.
                if #available(iOS 26.0, *),
                   ContinuedProcessing.shared.backgroundCapable.contains(id) {
                    continue
                }
                processing.interrupted.insert(id)
                task.cancel()
            }
        } else {
            let ids = processing.interrupted
            processing.interrupted.removeAll()
            for id in ids {
                if let session = sessions.first(where: { $0.id == id }), session.status == .recorded {
                    startProcessing(session)
                }
            }
        }
    }

    /// Keep the screen on while recording or processing, so the app is never
    /// forced into the background mid-inference by the auto-lock timer.
    func setRecordingActive(_ active: Bool) {
        processing.recordingActive = active
        refreshKeepAwake()
    }

    func refreshKeepAwake() {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled =
            processing.recordingActive || !processing.bySession.isEmpty
        #endif
    }
}
