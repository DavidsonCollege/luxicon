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

@Suite struct BoundedTranscriptionTests {
    /// Records each call's sample count; returns canned text per call.
    private final class StubASR: TurnTranscriber {
        var supportsContext: Bool { false }
        var callSizes: [Int] = []
        var texts: [String]
        init(texts: [String] = []) { self.texts = texts }
        func transcribeTurn(_ audio: [Float], sampleRate: Int, context: [String]?) -> TranscriptionResult {
            callSizes.append(audio.count)
            let text = callSizes.count <= texts.count ? texts[callSizes.count - 1] : "chunk\(callSizes.count)"
            return TranscriptionResult(text: text, confidence: 0.5)
        }
    }

    @Test func shortAudioIsSingleChunk() {
        let ranges = MeetingPipeline.chunkRanges(sampleCount: 16000 * 30, sampleRate: 16000, maxSeconds: 60)
        #expect(ranges == [0..<(16000 * 30)])
    }

    @Test func emptyAudioHasNoChunks() {
        #expect(MeetingPipeline.chunkRanges(sampleCount: 0, sampleRate: 16000, maxSeconds: 60).isEmpty)
    }

    @Test func longAudioSplitsAtMaxAndCoversEverything() {
        let total = 16000 * 150  // 2.5 min → 60s + 60s + 30s
        let ranges = MeetingPipeline.chunkRanges(sampleCount: total, sampleRate: 16000, maxSeconds: 60)
        #expect(ranges.count == 3)
        #expect(ranges[0].count == 16000 * 60 && ranges[1].count == 16000 * 60 && ranges[2].count == 16000 * 30)
        #expect(ranges.first?.lowerBound == 0 && ranges.last?.upperBound == total)
        for (a, b) in zip(ranges, ranges.dropFirst()) { #expect(a.upperBound == b.lowerBound) }
    }

    @Test func subSecondTailFoldsIntoPreviousChunk() {
        let total = 16000 * 60 + 8000  // 60s + 0.5s tail
        let ranges = MeetingPipeline.chunkRanges(sampleCount: total, sampleRate: 16000, maxSeconds: 60)
        #expect(ranges == [0..<total])  // tail folded; last chunk may exceed maxSeconds by design
    }

    @Test func longTurnTranscribesInChunksAndJoinsText() {
        let asr = StubASR(texts: ["first part", "second part", "tail"])
        let samples = [Float](repeating: 0, count: 16000 * 150)
        let result = MeetingPipeline.transcribeBounded(samples, asr: asr, sampleRate: 16000, context: nil)
        #expect(asr.callSizes == [16000 * 60, 16000 * 60, 16000 * 30])
        #expect(result.text == "first part second part tail")
        #expect(abs(result.confidence - 0.5) < 0.0001)
    }

    @Test func emptyChunkTextIsSkippedInJoin() {
        let asr = StubASR(texts: ["hello", "  ", "world"])
        let samples = [Float](repeating: 0, count: 16000 * 150)
        let result = MeetingPipeline.transcribeBounded(samples, asr: asr, sampleRate: 16000, context: nil)
        #expect(result.text == "hello world")
    }

    @Test func shortTurnIsOneASRCall() {
        let asr = StubASR(texts: ["short"])
        let samples = [Float](repeating: 0, count: 16000 * 20)
        let result = MeetingPipeline.transcribeBounded(samples, asr: asr, sampleRate: 16000, context: nil)
        #expect(asr.callSizes == [16000 * 20])
        #expect(result.text == "short")
    }
}

@Suite struct ASREngineDecodeTests {
    private struct Wrapper: Codable { var asrEngine: ASREngine? }

    @Test func decodesParakeet() throws {
        let w = try JSONDecoder().decode(Wrapper.self, from: Data(#"{"asrEngine":"parakeet"}"#.utf8))
        #expect(w.asrEngine == .parakeet)
    }

    /// store.json written by a build that still offered the experimental
    /// Qwen3 engine must not fail to decode — it falls back to the default.
    @Test func retiredQwen3ValueFallsBackToParakeet() throws {
        let w = try JSONDecoder().decode(Wrapper.self, from: Data(#"{"asrEngine":"qwen3"}"#.utf8))
        #expect(w.asrEngine == .parakeet)
    }

    @Test func missingValueStaysNil() throws {
        let w = try JSONDecoder().decode(Wrapper.self, from: Data(#"{}"#.utf8))
        #expect(w.asrEngine == nil)
    }
}

@Suite struct ASREngineDefaultTests {
    @Test func resolvedDefaultPrefersAppleSpeechWhenAvailable() {
        #expect(ASREngine.resolvedDefault(appleSpeechAvailable: true) == .appleSpeech)
        #expect(ASREngine.resolvedDefault(appleSpeechAvailable: false) == .parakeet)
    }

    @Test func appleSpeechRawValueIsStable() {
        // Persisted in store.json and passed as a CLI flag — must never change.
        #expect(ASREngine.appleSpeech.rawValue == "appleSpeech")
    }
}

@Suite struct TranscriptionYieldTests {
    private func span(_ start: Double, _ end: Double) -> MeetingPipeline.TurnSpan {
        MeetingPipeline.TurnSpan(speakerId: 0, start: start, end: end)
    }

    @Test func allTurnsEmptyOnRealSpeechThrows() {
        // 3 diarized turns, 30 s of speech, zero transcribed text: the
        // engine broke at runtime (e.g. appleSpeech asset evicted) — that
        // must surface as a failure, not a .ready empty transcript.
        #expect(throws: TranscriptionEmptyError.self) {
            try MeetingPipeline.checkTranscriptionYield(
                turns: [], spans: [span(0, 10), span(10, 20), span(20, 30)])
        }
    }

    @Test func shortRecordingsMayLegitimatelyYieldNothing() throws {
        // A cough or mic test: diarization finds a blip, ASR rightly hears
        // no words. Below the speech threshold the empty result stands.
        try MeetingPipeline.checkTranscriptionYield(turns: [], spans: [span(0, 4)])
    }

    @Test func anyTranscribedTurnPasses() throws {
        let turn = TranscriptTurn(id: 0, speakerId: 0, start: 0, end: 30, text: "hello")
        try MeetingPipeline.checkTranscriptionYield(
            turns: [turn], spans: [span(0, 30), span(30, 60)])
    }

    @Test func noSpansPasses() throws {
        try MeetingPipeline.checkTranscriptionYield(turns: [], spans: [])
    }
}
