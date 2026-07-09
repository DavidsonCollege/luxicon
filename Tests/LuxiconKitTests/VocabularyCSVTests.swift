import Testing
@testable import LuxiconKit

@Suite struct VocabularyCSVTests {
    @Test func exportParseRoundTrip() throws {
        let entries = [
            VocabularyEntry(term: "Choreo", soundsLike: ["corio", "correo"],
                            category: "project", notes: "Platform, not the dance"),
            VocabularyEntry(term: "Oracle HCM", soundsLike: [], category: "acronym", notes: nil),
        ]
        let parsed = try VocabularyCSV.parse(VocabularyCSV.export(entries))
        #expect(parsed == entries)
    }

    @Test func parseHandlesQuotedFieldsAndCommas() throws {
        let csv = """
        term,sounds_like,category,notes
        "Lake Norman","lake normin; lakenorman",place,"North of campus, big"
        """
        let parsed = try VocabularyCSV.parse(csv)
        #expect(parsed.count == 1)
        #expect(parsed[0].term == "Lake Norman")
        #expect(parsed[0].soundsLike == ["lake normin", "lakenorman"])
        #expect(parsed[0].notes == "North of campus, big")
    }

    @Test func templateCommentRowsAreSkippedOnImport() throws {
        let template = VocabularyCSV.template(existing: [VocabularyEntry(term: "Choreo")])
        let parsed = try VocabularyCSV.parse(template)
        #expect(parsed == [VocabularyEntry(term: "Choreo")])
    }

    @Test func emptyFileThrows() {
        #expect(throws: VocabularyCSV.ParseError.self) {
            try VocabularyCSV.parse("term,sounds_like,category,notes\n")
        }
    }
}

@Suite struct VocabularyAliasTests {
    @Test func exactAliasReplaced() {
        let entries = [VocabularyEntry(term: "Choreo", soundsLike: ["correo"])]
        let out = VocabularyCorrector.correct("We deployed correo yesterday.", entries: entries)
        #expect(out == "We deployed Choreo yesterday.")
    }

    @Test func multiWordAliasReplaced() {
        let entries = [VocabularyEntry(term: "Oracle HCM", soundsLike: ["oracle h c m"])]
        let out = VocabularyCorrector.correct("Check oracle h c m for the goal.", entries: entries)
        #expect(out == "Check Oracle HCM for the goal.")
    }

    @Test func aliasPreservesPunctuation() {
        let entries = [VocabularyEntry(term: "Choreo", soundsLike: ["correo"])]
        let out = VocabularyCorrector.correct("Is that correo?", entries: entries)
        #expect(out == "Is that Choreo?")
    }

    @Test func aliasBeatsDictionaryProtection() {
        // "carrier" is a real English word, so fuzzy repair would never touch
        // it — but an explicit alias is user intent and replaces exactly.
        let entries = [VocabularyEntry(term: "Choreo", soundsLike: ["carrier"])]
        let out = VocabularyCorrector.correct("The carrier pipeline is green.", entries: entries)
        #expect(out == "The Choreo pipeline is green.")
    }
}
