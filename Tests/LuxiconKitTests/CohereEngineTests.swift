import Foundation
import Testing
import AudioCommon
import SpeechVAD
@testable import LuxiconKit

@Suite struct CohereEngineTests {
    // MARK: Short-turn guard

    @Test func guardEmptiesStockCloserOnShortTurn() {
        #expect(ShortTurnGuard.filter("Thank you.", duration: 0.95) == "")
        #expect(ShortTurnGuard.filter("Thanks.", duration: 0.5) == "")
        #expect(ShortTurnGuard.filter("Thank you very much.", duration: 0.99) == "")
        #expect(ShortTurnGuard.filter("Bye.", duration: 0.3) == "")
    }

    @Test func guardKeepsRealShortAnswers() {
        #expect(ShortTurnGuard.filter("Okay.", duration: 0.6) == "Okay.")
        #expect(ShortTurnGuard.filter("Yeah.", duration: 0.4) == "Yeah.")
        // Exact match only: a closer inside a longer utterance is real speech.
        #expect(ShortTurnGuard.filter("Thank you. Bye.", duration: 0.9) == "Thank you. Bye.")
    }

    @Test func guardKeepsClosersOnLongTurns() {
        #expect(ShortTurnGuard.filter("Thank you.", duration: 1.2) == "Thank you.")
        #expect(ShortTurnGuard.filter("Bye.", duration: ShortTurnGuard.maxDuration) == "Bye.")
    }

    @Test func guardIgnoresSurroundingWhitespace() {
        #expect(ShortTurnGuard.filter(" Thank you.\n", duration: 0.8) == "")
    }

    /// Engines other than Cohere pass turn text through untouched — the guard
    /// is a Cohere-specific hallucination fix, not a pipeline-wide filter.
    @Test func defaultTurnTextFilterIsIdentity() {
        final class Plain: TurnTranscriber {
            var supportsContext: Bool { false }
            func transcribeTurn(_ audio: [Float], sampleRate: Int, context: [String]?) -> TranscriptionResult {
                TranscriptionResult(text: "")
            }
        }
        #expect(Plain().filterTurnText("Thank you.", turnDuration: 0.5) == "Thank you.")
    }

    // MARK: Engine selection

    @Test func cohereRawValueRoundTrips() throws {
        #expect(ASREngine.cohere.rawValue == "cohere")
        let data = try JSONEncoder().encode([ASREngine.cohere])
        #expect(String(decoding: data, as: UTF8.self) == #"["cohere"]"#)
        #expect(try JSONDecoder().decode([ASREngine].self, from: data) == [.cohere])
    }

    @Test func cohereUnavailableOnIOSResolvesToDefault() {
        #if os(iOS)
        #expect(!ASREngine.cohere.isAvailable)
        #expect(ASREngine.resolved(.cohere) == ASREngine.resolvedDefault())
        #else
        #expect(ASREngine.cohere.isAvailable)
        #expect(ASREngine.resolved(.cohere) == .cohere)
        #endif
    }

    @Test func resolvedFallsBackToDefaultForNilAndKeepsAvailableChoices() {
        #expect(ASREngine.resolved(nil) == ASREngine.resolvedDefault())
        #expect(ASREngine.resolved(.parakeet) == .parakeet)
        #expect(ASREngine.parakeet.isAvailable)
    }

    // MARK: Pipeline wiring

    /// Emits one fixed diarization; never touched for embeddings here.
    private final class FixedDiarizer: SpeakerDiarizer {
        let segments: [DiarizedSegment]
        init(_ segments: [DiarizedSegment]) { self.segments = segments }
        var embeddingModel: WeSpeakerModel { fatalError("not used by process") }
        func diarize(
            audio: [Float], sampleRate: Int, config: DiarizationConfig,
            progressHandler: ((Float, String) -> Bool)?
        ) -> DiarizationResult {
            DiarizationResult(segments: segments, numSpeakers: 1, speakerEmbeddings: [])
        }
    }

    /// Hallucinates a closer and records what the pipeline hands the filter.
    private final class ClosingASR: TurnTranscriber {
        var sliceSeconds: [Double] = []
        var filterDurations: [Double] = []
        var supportsContext: Bool { false }
        func transcribeTurn(_ audio: [Float], sampleRate: Int, context: [String]?) -> TranscriptionResult {
            sliceSeconds.append(Double(audio.count) / Double(sampleRate))
            return TranscriptionResult(text: "Thank you.")
        }
        func filterTurnText(_ text: String, turnDuration: Double) -> String {
            filterDurations.append(turnDuration)
            return ShortTurnGuard.filter(text, duration: turnDuration)
        }
    }

    /// The guard must judge the diarized span (0.95 s), not the padded slice
    /// the engine hears (0.95 + 2 × 0.15 = 1.25 s) — otherwise it never fires.
    @Test func pipelinePassesUnpaddedTurnDurationToFilter() throws {
        let asr = ClosingASR()
        let pipeline = MeetingPipeline(
            diarizer: FixedDiarizer([DiarizedSegment(startTime: 1.0, endTime: 1.95, speakerId: 0)]),
            asr: asr)
        let audio = [Float](repeating: 0, count: 3 * MeetingPipeline.sampleRate)
        // `process` minus its MLX cache bounds (which need a Metal library
        // the test host doesn't have): diarize → turns → transcribeTurns.
        let options = MeetingPipeline.Options.oneOnOne
        let diarized = pipeline.diarizer.diarize(
            audio: audio, sampleRate: MeetingPipeline.sampleRate, config: options.diarization)
        let spans = MeetingPipeline.buildTurns(segments: diarized.segments, mergeGap: options.turnMergeGap)
        var records: [TurnRecord] = []
        let turns = try pipeline.transcribeTurns(
            spans, audio: audio, vocabulary: [], options: options, onTurn: { records.append($0) })

        #expect(asr.filterDurations.count == 1)
        #expect(abs((asr.filterDurations.first ?? 0) - 0.95) < 1e-4)
        #expect(abs((asr.sliceSeconds.first ?? 0) - 1.25) < 1e-3)
        #expect(turns.isEmpty)
        #expect(records.map(\.text) == [""])
    }

    // MARK: Load stage text

    #if os(macOS)
    /// Download progress carries a percentage; once the bytes are on disk the
    /// weights load for seconds with no callbacks, so the text drops the
    /// percentage instead of sitting at "100%".
    @Test func cohereLoadStageTextIsTruthful() {
        #expect(CohereTurnTranscriber.loadStage(fraction: 0, downloading: true)
            == "Downloading Cohere model… 0%")
        #expect(CohereTurnTranscriber.loadStage(fraction: 0.426, downloading: true)
            == "Downloading Cohere model… 42%")
        // 99.9% is not done: never round up to a "100%" that then stalls.
        #expect(CohereTurnTranscriber.loadStage(fraction: 0.999, downloading: true)
            == "Downloading Cohere model… 99%")
        #expect(CohereTurnTranscriber.loadStage(fraction: 1, downloading: false)
            == "Loading Cohere model…")
    }
    #endif
}
