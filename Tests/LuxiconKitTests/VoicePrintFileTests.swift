import Testing
import Foundation
@testable import LuxiconKit

@Suite struct VoicePrintFileTests {
    private let sample = VoicePrintFile(
        name: "Sam", createdAt: Date(timeIntervalSince1970: 1_780_000_000),
        embedding: [0.25, -0.5, 1])

    @Test func voicePrintRoundTrips() throws {
        let decoded = try #require(VoicePrintFile.decode(sample.encoded()))
        #expect(decoded == sample)
        #expect(decoded.kind == "voiceprint")
        #expect(decoded.schemaVersion == 1)
    }

    @Test func decodeRejectsWrongKind() throws {
        var file = sample
        file.kind = "one-on-one"
        #expect(VoicePrintFile.decode(try file.encoded()) == nil)
    }

    @Test func decodeRejectsWrongSchemaVersion() throws {
        var file = sample
        file.schemaVersion = 2
        #expect(VoicePrintFile.decode(try file.encoded()) == nil)
    }

    @Test func decodeRejectsEmptyEmbedding() throws {
        let file = VoicePrintFile(name: "Sam", embedding: [])
        #expect(VoicePrintFile.decode(try file.encoded()) == nil)
    }

    @Test func decodeRejectsGarbage() {
        #expect(VoicePrintFile.decode(Data("nope".utf8)) == nil)
    }

    @Test func libraryScanIgnoresVoicePrint() throws {
        let sessions = TranscriptLibrary.parse(
            try sample.encoded(), sourceFile: VoicePrintFile.filename, folderName: nil)
        #expect(sessions.isEmpty)
    }
}
