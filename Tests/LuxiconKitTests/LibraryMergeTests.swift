import Testing
import Foundation
@testable import LuxiconKit

@Suite struct LibraryMergeTests {
    private func session(person: String, id: UUID? = nil, source: String? = nil) -> TranscriptLibrary.Session {
        TranscriptLibrary.Session(
            person: person,
            transcript: MeetingTranscript(
                title: "1-on-1 with \(person)",
                date: Date(timeIntervalSince1970: 1_780_000_000),
                duration: 60, turns: []),
            summary: nil, sourceFile: "\(person).json",
            sessionId: id, source: source)
    }

    @Test func phoneSessionsDropOwnedAndMac() {
        let owned = UUID(), orphan = UUID()
        let phone = session(person: "Phone")
        let all = [
            phone,
            session(person: "Owned", id: owned, source: "mac"),
            session(person: "Orphan", id: orphan, source: "mac"),
        ]
        let kept = LibraryMerge.phoneSessions(all, ownedIds: [owned])
        #expect(kept.map(\.person) == ["Phone"])
        let orphans = LibraryMerge.orphanMacSessions(all, ownedIds: [owned])
        #expect(orphans.map(\.person) == ["Orphan"])
    }

    @Test func phoneSessionsDropOwnedIdsRegardlessOfSource() {
        let owned = UUID()
        // A phone push of a session the Mac app also owns (same id) is dropped.
        let all = [session(person: "Dup", id: owned), session(person: "Other", id: UUID())]
        #expect(LibraryMerge.phoneSessions(all, ownedIds: [owned]).map(\.person) == ["Other"])
    }

    @Test func libraryOnlyNamesIsCaseInsensitive() {
        let sessions = [
            session(person: "sam"), session(person: "Riley"), session(person: "Unfiled"),
            session(person: "Riley"),
        ]
        #expect(LibraryMerge.libraryOnlyNames(sessions, knownNames: ["Sam"]) == ["Riley"])
    }
}
