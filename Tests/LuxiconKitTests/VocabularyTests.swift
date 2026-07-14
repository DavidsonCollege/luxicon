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

    @Test func contextStringBuildsAndSkipsEmpty() {
        #expect(VocabularyCorrector.contextString(for: []) == nil)
        #expect(VocabularyCorrector.contextString(for: [VocabularyEntry(term: "  ")]) == nil)
        let ctx = VocabularyCorrector.contextString(for: [
            VocabularyEntry(term: "Sam Rivera"), VocabularyEntry(term: "Choreo"),
        ])
        #expect(ctx?.contains("Sam Rivera, Choreo") == true)
    }
}

@Suite struct ProtectedAliasTests {
    /// The real-world failure: an LLM-generated vocab file mapped "this" → SIS
    /// and "have" → AV, rewriting every occurrence in 45 minutes of meeting.
    @Test func functionWordAliasesAreNeverApplied() {
        let entries = [
            VocabularyEntry(term: "SIS", soundsLike: ["sis", "this"]),
            VocabularyEntry(term: "AV", soundsLike: ["have", "A V"]),
        ]
        let text = "I think this is the best we have."
        let out = VocabularyCorrector.correct(text, entries: entries)
        #expect(out.contains("this"))
        #expect(out.contains("have"))
        #expect(!out.contains("SIS"))
        #expect(!out.contains("AV"))
    }

    @Test func rareRealWordAliasesStillApply() {
        let entries = [VocabularyEntry(term: "CTL", soundsLike: ["cattle"])]
        let out = VocabularyCorrector.correct("The cattle office called.", entries: entries)
        #expect(out == "The CTL office called.")
    }

    @Test func multiWordAliasesWithFunctionWordsStillApply() {
        let entries = [VocabularyEntry(term: "Ad Astra", soundsLike: ["at astra"])]
        let out = VocabularyCorrector.correct("We reviewed at astra yesterday.", entries: entries)
        #expect(out == "We reviewed Ad Astra yesterday.")
    }

    @Test func safeAliasesOfTheSameEntrySurviveProtectedSiblings() {
        let entries = [VocabularyEntry(term: "SIS", soundsLike: ["this", "cysts"])]
        let out = VocabularyCorrector.correct("The cysts migration and this plan.", entries: entries)
        #expect(out.contains("SIS migration"))
        #expect(out.contains("this plan"))
    }

    @Test func ignoredAliasesReportsForLint() {
        let entries = [
            VocabularyEntry(term: "SIS", soundsLike: ["sis", "this", "cysts"]),
            VocabularyEntry(term: "AV", soundsLike: ["have"]),
            VocabularyEntry(term: "HECVAT", soundsLike: ["heck vat"]),
        ]
        let ignored = VocabularyCorrector.ignoredAliases(in: entries)
        #expect(ignored.map(\.alias).sorted() == ["have", "this"])
    }
}
