import Foundation
import Testing
@testable import LuxiconKit

/// The Mac app's ownership rule for `~/Luxicon`: it writes over, renames, or
/// deletes only files whose envelope says `"source": "mac"` with the session's
/// own id. Everything runs in a fresh temp directory.
@Suite struct LibraryFilesTests {
    private let base = "Sam 2026-05-28 ABCDEF12.json"

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryFilesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func envelope(sessionId: UUID? = nil, source: String? = nil) throws -> Data {
        let transcript = MeetingTranscript(
            title: "1-on-1 with Sam", date: Date(timeIntervalSince1970: 1_780_000_000),
            duration: 60, turns: [])
        return try TranscriptExport.json(transcript, sessionId: sessionId, source: source)
    }

    @Test func candidatesStartWithThePhoneName() {
        let names = LibraryFiles.candidates(base: base)
        #expect(names.first == base)
        #expect(names[1] == "Sam 2026-05-28 ABCDEF12 (Mac).json")
        #expect(names[2] == "Sam 2026-05-28 ABCDEF12 (Mac 2).json")
        #expect(names.last == "Sam 2026-05-28 ABCDEF12 (Mac 20).json")
        #expect(names.count == 21)
        #expect(Set(names).count == names.count)
    }

    @Test func phoneFileAtBaseNameIsNotOwnedAndTheNextNameIsChosen() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        // A phone push of the same session: same id, but no "mac" source.
        let phone = dir.appendingPathComponent(base)
        try envelope(sessionId: id).write(to: phone)
        #expect(!LibraryFiles.isOwned(phone, by: id))
        #expect(!LibraryFiles.isFree(phone, for: id))
        #expect(LibraryFiles.freeName(base: base, in: dir, for: id) == "Sam 2026-05-28 ABCDEF12 (Mac).json")
    }

    @Test func macFileForAnotherSessionIsNotOwned() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(base)
        try envelope(sessionId: UUID(), source: TranscriptExport.macSource).write(to: url)
        let id = UUID()
        #expect(!LibraryFiles.isOwned(url, by: id))
        #expect(LibraryFiles.freeName(base: base, in: dir, for: id) == "Sam 2026-05-28 ABCDEF12 (Mac).json")
    }

    @Test func macFileForThisSessionIsOwned() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        let url = dir.appendingPathComponent(base)
        try envelope(sessionId: id, source: TranscriptExport.macSource).write(to: url)
        #expect(LibraryFiles.isOwned(url, by: id))
        #expect(LibraryFiles.isFree(url, for: id))
        #expect(LibraryFiles.freeName(base: base, in: dir, for: id) == base)
    }

    @Test func unreadableOrForeignContentIsNeverOwned() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        let garbage = dir.appendingPathComponent("garbage.json")
        try Data("not json".utf8).write(to: garbage)
        #expect(!LibraryFiles.isOwned(garbage, by: id))
        #expect(!LibraryFiles.isOwned(dir.appendingPathComponent("missing.json"), by: id))
        #expect(LibraryFiles.isFree(dir.appendingPathComponent("missing.json"), for: id))
    }

    @Test func danglingSymlinkIsNotFree() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appendingPathComponent(base)
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: dir.appendingPathComponent("nowhere.json").path)
        let id = UUID()
        #expect(!LibraryFiles.isFree(link, for: id))
        #expect(LibraryFiles.freeName(base: base, in: dir, for: id) == "Sam 2026-05-28 ABCDEF12 (Mac).json")
    }

    @Test func directoryIsNotFree() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent(base, isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let id = UUID()
        #expect(!LibraryFiles.isFree(sub, for: id))
        #expect(LibraryFiles.freeName(base: base, in: dir, for: id) == "Sam 2026-05-28 ABCDEF12 (Mac).json")
    }

    @Test func allNamesTakenGivesNil() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let phone = try envelope()
        for name in LibraryFiles.candidates(base: base) {
            try phone.write(to: dir.appendingPathComponent(name))
        }
        #expect(LibraryFiles.freeName(base: base, in: dir, for: UUID()) == nil)
    }
}
