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
    /// Tracks scene phase so a cancelled task finishing after the app is
    /// already foreground again can resume itself (the foreground sweep may
    /// have run before the task wrote its status back).
    @ObservationIgnored var inBackground = false
    /// True while the record screen is capturing audio.
    @ObservationIgnored var recordingActive = false

    func info(for id: UUID) -> Info? { bySession[id] }
}

extension Store {
    private static let processingState = ProcessingState()
    var processing: ProcessingState { Self.processingState }

    /// Kick off diarization + transcription for a recorded session.
    func startProcessing(_ session: SessionRecord) {
        // .recorded/.failed start normally; .ready allows Re-transcribe. Only
        // a session already being processed is refused.
        guard session.status != .processing, processing.tasks[session.id] == nil else { return }
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
                // Decode off the main actor: an hour-long file takes seconds
                // and this Task otherwise inherits Store's @MainActor.
                let audio = try await Task.detached {
                    try MeetingPipeline.loadAudio(url: audioURL)
                }.value
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
            // Merge onto the CURRENT stored record: fields that changed during
            // the minutes of pipeline work (a push outcome, a speaker rename)
            // must not be reverted by writing back this task's stale copy.
            if var current = self.sessions.first(where: { $0.id == sessionId }) {
                current.status = s.status
                current.transcript = s.transcript
                current.summary = s.summary
                current.errorMessage = s.errorMessage
                if s.status == .ready {
                    // New transcript ⇒ any earlier push refers to older bytes.
                    current.lastPushDate = nil
                    current.lastPushError = nil
                }
                update(current)
                s = current
            }
            refreshKeepAwake()
            if s.status == .ready, self.autoSummarize {
                self.startSummarizing(s)  // auto-push fires after the summary lands
            } else if s.status == .ready {
                self.autoPushIfEnabled(s)
            } else if s.status == .recorded, !processing.inBackground,
                      processing.interrupted.remove(sessionId) != nil {
                // Backgrounding cancelled this task, but the app returned to
                // the foreground before the status write landed — the sweep in
                // handleScenePhaseChange already ran and missed it. Resume now.
                self.startProcessing(s)
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
        processing.inBackground = toBackground
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
                } else if processing.tasks[id] != nil {
                    // Cancelled task hasn't written its status back yet; leave
                    // it marked so its completion can resume it (see above).
                    processing.interrupted.insert(id)
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
