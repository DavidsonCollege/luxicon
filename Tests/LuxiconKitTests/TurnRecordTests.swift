import Foundation
import Testing
import AudioCommon
import SpeechVAD
@testable import LuxiconKit

@Suite struct TurnRecordTests {
    @Test func diarizationFileRoundTrips() throws {
        let original = DiarizationResult(
            segments: [
                DiarizedSegment(startTime: 0.5, endTime: 4.25, speakerId: 0),
                DiarizedSegment(startTime: 4.5, endTime: 9.0, speakerId: 1),
            ],
            numSpeakers: 2,
            speakerEmbeddings: [[0.1, 0.2], [0.3, 0.4]])
        let data = try JSONEncoder().encode(DiarizationFile(original))
        let restored = try JSONDecoder().decode(DiarizationFile.self, from: data).result

        #expect(restored.numSpeakers == 2)
        #expect(restored.segments.count == 2)
        for (a, b) in zip(original.segments, restored.segments) {
            #expect(a.startTime == b.startTime)
            #expect(a.endTime == b.endTime)
            #expect(a.speakerId == b.speakerId)
        }
        #expect(restored.speakerEmbeddings == original.speakerEmbeddings)
    }
}
