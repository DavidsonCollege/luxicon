import Foundation
import Testing
@testable import LuxiconKit

@Suite struct SyncTimeoutTests {
    @Test func timeoutFiresOnCancellableSlowWork() async {
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: SyncPushError.self) {
            try await LuxiconSync.withTimeout(0.2, onTimeout: SyncPushError.noListenerFound) {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
        // The old implementation hung here for the full sleep; must return fast.
        #expect(clock.now - start < .seconds(5))
    }

    @Test func fastWorkWinsTheRace() async throws {
        let value = try await LuxiconSync.withTimeout(5, onTimeout: SyncPushError.noListenerFound) {
            42
        }
        #expect(value == 42)
    }
}

@Suite struct SyncHelperTests {
    @Test func sanitizedFilenameBlocksTraversal() {
        #expect(!LuxiconSync.sanitizedFilename("../../etc/passwd").contains("/"))
        #expect(!LuxiconSync.sanitizedFilename("..\\x").contains("\\"))
        #expect(LuxiconSync.sanitizedFilename(".sync-token").hasPrefix("session-"))
        #expect(LuxiconSync.sanitizedFilename("").hasPrefix("session-"))
        #expect(LuxiconSync.sanitizedFilename("a:b").hasSuffix(".json"))
        #expect(LuxiconSync.sanitizedFilename("Sam 2026-07-09.json") == "Sam 2026-07-09.json")
    }

    @Test func sessionFilenameMatchesPhoneFormat() {
        let id = UUID(uuidString: "ABCDEF12-0000-0000-0000-000000000000")!
        let name = LuxiconSync.sessionFilename(
            person: "Sam", date: Date(timeIntervalSince1970: 1_780_000_000), id: id)
        #expect(name == "Sam 2026-05-28 ABCDEF12.json")
    }

    @Test func sessionFilenameSanitizesSlashes() {
        let name = LuxiconSync.sessionFilename(person: "A/B", date: Date(), id: UUID())
        #expect(!name.contains("/"))
    }

    @Test func frameIsLengthPrefixed() {
        let payload = Data("hello".utf8)
        let framed = LuxiconSync.frame(payload)
        #expect(framed.count == 4 + payload.count)
        let length = framed.prefix(4).withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self).bigEndian) }
        #expect(length == payload.count)
        #expect(framed.dropFirst(4) == payload)
    }

    @Test func frameCapIsSane() {
        // The listener buffers a whole frame in RAM; the cap bounds that.
        #expect(LuxiconSync.maxFrameBytes == 64 * 1024 * 1024)
    }

    @Test func tokenIsLongAndInAlphabet() {
        let token = LuxiconSync.generateToken()
        #expect(token.count == 20)
        let alphabet = Set("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        #expect(token.allSatisfy { alphabet.contains($0) })
    }
}
