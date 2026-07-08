import Foundation
import SitdownKit

/// Live progress for sessions currently being processed.
@Observable @MainActor
final class ProcessingState {
    struct Info: Equatable {
        var fraction: Double
        var stage: String
    }
    var bySession: [UUID: Info] = [:]

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

        let sessionId = s.id
        let audioURL = audioURL(for: s)
        let enrollments = enrollments
        let personName = person(id: s.personId)?.name

        Task {
            do {
                let audio = try MeetingPipeline.loadAudio(url: audioURL)
                var transcript = try await PipelineService.shared.process(
                    audio: audio,
                    title: s.title,
                    date: s.date,
                    enrollments: enrollments
                ) { fraction, stage in
                    Task { @MainActor in
                        self.processing.bySession[sessionId] = .init(fraction: fraction, stage: stage)
                    }
                }
                if let personName {
                    transcript.nameRemainingSpeaker(personName)
                }
                s.transcript = transcript
                s.status = .ready
            } catch {
                s.status = .failed
                s.errorMessage = "\(error)"
            }
            processing.bySession[s.id] = nil
            update(s)
        }
    }
}
