import Foundation
import Testing
import AudioCommon
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
}
