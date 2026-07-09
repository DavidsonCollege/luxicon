import Testing
@testable import LuxiconKit

@Suite struct VocabularyCorrectorTests {
    @Test func fixesNearMissSingleWord() {
        let corrected = VocabularyCorrector.correct(
            "We migrated everything to Corio last week.",
            vocabulary: ["Choreo"])
        #expect(corrected == "We migrated everything to Choreo last week.")
    }

    @Test func fixesMultiWordName() {
        let corrected = VocabularyCorrector.correct(
            "I talked with Sam Riviera about the budget.",
            vocabulary: ["Sam Rivera"])
        #expect(corrected == "I talked with Sam Rivera about the budget.")
    }

    @Test func preservesPunctuation() {
        let corrected = VocabularyCorrector.correct(
            "Was that Corio?",
            vocabulary: ["Choreo"])
        #expect(corrected == "Was that Choreo?")
    }

    @Test func leavesExactMatchesAlone() {
        let text = "Choreo is working well."
        #expect(VocabularyCorrector.correct(text, vocabulary: ["Choreo"]) == text)
    }

    @Test func realEnglishWordsAreProtected() {
        // "chorus" is within edit budget of "Choreo" but is a real word.
        let text = "The chorus sang loudly."
        #expect(VocabularyCorrector.correct(text, vocabulary: ["Choreo"]) == text)
        // "data" is one edit from "Dana" but must never be rewritten.
        let text2 = "The data looks solid."
        #expect(VocabularyCorrector.correct(text2, vocabulary: ["Dana"]) == text2)
    }

    @Test func doesNotCorrectBeyondEditBudget() {
        let text = "We chose carbon for the frame."
        #expect(VocabularyCorrector.correct(text, vocabulary: ["Choreo"]) == text)
    }

    @Test func requiresMatchingFirstLetter() {
        // "Maven" vs "Raven": similarity 0.8 but different first letter.
        let text = "The maven project built fine."
        #expect(VocabularyCorrector.correct(text, vocabulary: ["Raven"]) == text)
    }

    @Test func ignoresShortTerms() {
        let text = "So it goes."
        #expect(VocabularyCorrector.correct(text, vocabulary: ["it", "so"]) == text)
    }

    @Test func similarityMetric() {
        #expect(VocabularyCorrector.similarity("choreo", "choreo") == 1.0)
        #expect(VocabularyCorrector.similarity("corio", "choreo") > 0.6)
        #expect(VocabularyCorrector.similarity("abc", "xyz") == 0.0)
    }

    @Test func contextStringBuildsAndSkipsEmpty() {
        #expect(VocabularyCorrector.contextString(for: []) == nil)
        #expect(VocabularyCorrector.contextString(for: ["  "]) == nil)
        let ctx = VocabularyCorrector.contextString(for: ["Sam Rivera", "Choreo"])
        #expect(ctx?.contains("Sam Rivera, Choreo") == true)
    }
}
