import Testing
import Foundation
@testable import LuxiconKit

@Suite struct TranscriptLibraryTests {
    private func transcript(title: String, day: Int, speaker: String? = "Sam") -> MeetingTranscript {
        MeetingTranscript(
            title: title,
            date: Date(timeIntervalSince1970: 1_780_000_000 + Double(day) * 86_400),
            duration: 120,
            turns: [
                TranscriptTurn(id: 0, speakerId: 0, speakerName: "JD", start: 0, end: 70,
                               text: "How is the staging environment?"),
                TranscriptTurn(id: 1, speakerId: 1, speakerName: speaker, start: 71, end: 120,
                               text: "Stable since the rebuild."),
            ]
        )
    }

    private func encode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try! encoder.encode(value)
    }

    @Test func parsesSingleSessionEnvelopeAndInfersPersonFromTitle() {
        struct Envelope: Encodable {
            let schemaVersion = 1, kind = "one-on-one"
            let transcript: MeetingTranscript
        }
        let data = encode(Envelope(transcript: transcript(title: "1-on-1 with Sam Rivera", day: 0)))
        let sessions = TranscriptLibrary.parse(data, sourceFile: "a.json", folderName: nil)
        #expect(sessions.count == 1)
        #expect(sessions[0].person == "Sam Rivera")
    }

    @Test func parsesBundleWithPersonName() {
        struct Bundle: Encodable {
            let schemaVersion = 1, kind = "one-on-one-bundle"
            let personName: String
            let transcripts: [MeetingTranscript]
        }
        let data = encode(Bundle(personName: "Priya Patel", transcripts: [
            transcript(title: "Weekly", day: 0), transcript(title: "Weekly", day: 7),
        ]))
        let sessions = TranscriptLibrary.parse(data, sourceFile: "b.json", folderName: nil)
        #expect(sessions.count == 2)
        #expect(sessions.allSatisfy { $0.person == "Priya Patel" })
    }

    @Test func fallsBackToFolderThenUnfiled() {
        let bare = encode(transcript(title: "Untitled chat", day: 0))
        #expect(TranscriptLibrary.parse(bare, sourceFile: "c.json", folderName: "Josh")[0].person == "Josh")
        #expect(TranscriptLibrary.parse(bare, sourceFile: "c.json", folderName: nil)[0].person == "Unfiled")
    }

    @Test func garbageProducesNoSessions() {
        #expect(TranscriptLibrary.parse(Data("nope".utf8), sourceFile: "x.json", folderName: nil).isEmpty)
    }

    @Test func summaryWithUnknownShapeDoesNotHideTheSession() {
        // A schema drift in SessionSummary (v1.0.0 shipped with a required
        // `headline`; 6618b0a removed it) must degrade to summary-less, never
        // to the session disappearing from every MCP tool.
        struct AlienSummary: Encodable { let headline = "Topics" }  // no overview/generatedAt
        struct Envelope: Encodable {
            let schemaVersion = 1, kind = "one-on-one"
            let transcript: MeetingTranscript
            let summary: AlienSummary
        }
        let data = encode(Envelope(
            transcript: transcript(title: "1-on-1 with Sam Rivera", day: 0),
            summary: AlienSummary()))
        let sessions = TranscriptLibrary.parse(data, sourceFile: "d.json", folderName: nil)
        #expect(sessions.count == 1)
        #expect(sessions[0].summary == nil)
        #expect(sessions[0].person == "Sam Rivera")
    }

    @Test func searchFindsTurnWithContextAndPersonFilter() {
        var library = TranscriptLibrary()
        library.sessions = TranscriptLibrary.parse(
            encode(transcript(title: "1-on-1 with Sam", day: 0)),
            sourceFile: "a.json", folderName: nil)
        let hits = library.search("staging")
        #expect(hits.count == 1)
        #expect(hits[0].context.count == 2)
        #expect(library.search("staging", person: "Nobody").isEmpty)
    }

    @Test func talkTrendMatchesNamedSpeaker() {
        var library = TranscriptLibrary()
        library.sessions = TranscriptLibrary.parse(
            encode(transcript(title: "1-on-1 with Sam", day: 0, speaker: "Sam")),
            sourceFile: "a.json", folderName: nil)
        let trend = library.talkTrend(for: "Sam")
        #expect(trend.count == 1)
        #expect(abs((trend[0].personShare ?? 0) - 49.0 / 119.0) < 0.001)
    }
}
