import Testing
import Foundation
import AudioCommon
import SpeechVAD
@testable import LuxiconKit

@Suite struct TurnBuildingTests {
    @Test func mergesSameSpeakerWithinGap() {
        let segs = [
            DiarizedSegment(startTime: 0.0, endTime: 2.0, speakerId: 0),
            DiarizedSegment(startTime: 2.5, endTime: 4.0, speakerId: 0),
            DiarizedSegment(startTime: 4.25, endTime: 6.0, speakerId: 1),
            DiarizedSegment(startTime: 8.0, endTime: 9.0, speakerId: 0),
        ]
        let turns = MeetingPipeline.buildTurns(segments: segs, mergeGap: 1.0)
        #expect(turns == [
            .init(speakerId: 0, start: 0.0, end: 4.0),
            .init(speakerId: 1, start: 4.25, end: 6.0),
            .init(speakerId: 0, start: 8.0, end: 9.0),
        ])
    }

    @Test func doesNotMergeAcrossSpeakerChange() {
        let segs = [
            DiarizedSegment(startTime: 0, endTime: 1, speakerId: 0),
            DiarizedSegment(startTime: 1.1, endTime: 2, speakerId: 1),
            DiarizedSegment(startTime: 2.1, endTime: 3, speakerId: 0),
        ]
        let turns = MeetingPipeline.buildTurns(segments: segs, mergeGap: 1.0)
        #expect(turns.count == 3)
    }

    @Test func sortsUnorderedSegments() {
        let segs = [
            DiarizedSegment(startTime: 5, endTime: 6, speakerId: 1),
            DiarizedSegment(startTime: 0, endTime: 1, speakerId: 0),
        ]
        let turns = MeetingPipeline.buildTurns(segments: segs, mergeGap: 1.0)
        #expect(turns.first?.speakerId == 0)
    }
}

@Suite struct CapSpeakersTests {
    // Unit-length orthogonal-ish embeddings: spk2 is nearly spk0.
    private let embeddings: [[Float]] = [
        [1, 0, 0],
        [0, 1, 0],
        [0.99, 0.14, 0],
    ]

    @Test func foldsMinorSpeakerIntoNearestCentroid() {
        let result = DiarizationResult(
            segments: [
                DiarizedSegment(startTime: 0, endTime: 10, speakerId: 0),
                DiarizedSegment(startTime: 10, endTime: 18, speakerId: 1),
                DiarizedSegment(startTime: 18, endTime: 19, speakerId: 2),
            ],
            numSpeakers: 3,
            speakerEmbeddings: embeddings
        )
        let capped = MeetingPipeline.capSpeakers(result, to: 2)
        #expect(capped.numSpeakers == 2)
        // Speaker 2's segment should now belong to speaker 0 (nearest centroid).
        let reassigned = capped.segments.first { $0.startTime == 18 }
        #expect(reassigned?.speakerId == 0)
        #expect(capped.speakerEmbeddings.count == 2)
    }

    @Test func noopWhenUnderCap() {
        let result = DiarizationResult(
            segments: [DiarizedSegment(startTime: 0, endTime: 1, speakerId: 0)],
            numSpeakers: 1,
            speakerEmbeddings: [[1, 0]]
        )
        let capped = MeetingPipeline.capSpeakers(result, to: 2)
        #expect(capped.segments.count == 1)
        #expect(capped.numSpeakers == 1)
    }
}

@Suite struct EnrollmentMatchingTests {
    @Test func greedyAssignsBestMatchOncePerName() {
        let centroids: [[Float]] = [[1, 0], [0, 1]]
        let enrollments = [
            VoiceEnrollment(name: "Alice", embedding: [0.9, 0.1]),
            VoiceEnrollment(name: "Bob", embedding: [0.1, 0.9]),
        ]
        let matches = MeetingPipeline.matchEnrollments(
            centroids: centroids, enrollments: enrollments, threshold: 0.35)
        #expect(matches.count == 2)
        #expect(matches.contains { $0.speakerId == 0 && $0.name == "Alice" })
        #expect(matches.contains { $0.speakerId == 1 && $0.name == "Bob" })
    }

    @Test func rejectsBelowThreshold() {
        let matches = MeetingPipeline.matchEnrollments(
            centroids: [[1, 0]],
            enrollments: [VoiceEnrollment(name: "Alice", embedding: [0, 1])],
            threshold: 0.35
        )
        #expect(matches.isEmpty)
    }

    @Test func oneEnrollmentCannotClaimTwoSpeakers() {
        let matches = MeetingPipeline.matchEnrollments(
            centroids: [[1, 0], [0.95, 0.31]],
            enrollments: [VoiceEnrollment(name: "Alice", embedding: [1, 0])],
            threshold: 0.35
        )
        #expect(matches.count == 1)
        #expect(matches[0].speakerId == 0)
    }
}

@Suite struct ExportTests {
    private var sample: MeetingTranscript {
        MeetingTranscript(
            title: "Weekly 1:1",
            date: Date(timeIntervalSince1970: 1_780_000_000),
            duration: 125,
            turns: [
                TranscriptTurn(id: 0, speakerId: 0, speakerName: "Alice", start: 0, end: 70, text: "How was your week?"),
                TranscriptTurn(id: 1, speakerId: 1, start: 71, end: 125, text: "Pretty good."),
            ]
        )
    }

    @Test func markdownContainsHeaderStatsAndTurns() {
        let md = TranscriptExport.markdown(sample)
        #expect(md.contains("# 1-on-1: Weekly 1:1"))
        #expect(md.contains("**[00:00] Alice:** How was your week?"))
        #expect(md.contains("**[01:11] Speaker 2:** Pretty good."))
        #expect(md.contains("Alice (56% talk time, 1 turns)"))
    }

    @Test func jsonRoundTrips() throws {
        let data = try TranscriptExport.json(sample)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["schemaVersion"] as? Int == 1)
        let transcript = obj?["transcript"] as? [String: Any]
        #expect((transcript?["turns"] as? [[String: Any]])?.count == 2)
    }

    @Test func timestampFormatsHours() {
        #expect(TranscriptExport.timestamp(3725) == "1:02:05")
        #expect(TranscriptExport.timestamp(65) == "01:05")
    }

    @Test func statsComputeTalkShareAndLongestTurn() {
        let stats = sample.speakers
        #expect(stats.count == 2)
        #expect(abs(stats[0].talkShare - 70.0 / 124.0) < 0.001)
        #expect(stats[1].longestTurn == 54)
    }
}
