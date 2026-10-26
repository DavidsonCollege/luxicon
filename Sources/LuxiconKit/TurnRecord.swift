import Foundation
import AudioCommon
import SpeechVAD

/// One transcribed turn, emitted by `MeetingPipeline.process`'s `onTurn` hook
/// (including turns whose text ends up empty). Used by the CLI's `--turn-log`
/// for A/B comparison between engines and library versions.
public struct TurnRecord: Codable, Sendable {
    public var start: Double
    public var end: Double
    public var speakerId: Int
    public var text: String

    public init(start: Double, end: Double, speakerId: Int, text: String) {
        self.start = start
        self.end = end
        self.speakerId = speakerId
        self.text = text
    }
}

/// JSON form of a `DiarizationResult`, so several runs (engines, library
/// versions) can share byte-identical speaker turns.
public struct DiarizationFile: Codable {
    public struct Segment: Codable {
        public var start: Float
        public var end: Float
        public var speaker: Int
    }

    public var segments: [Segment]
    public var numSpeakers: Int
    public var speakerEmbeddings: [[Float]]

    public init(_ result: DiarizationResult) {
        segments = result.segments.map {
            Segment(start: $0.startTime, end: $0.endTime, speaker: $0.speakerId)
        }
        numSpeakers = result.numSpeakers
        speakerEmbeddings = result.speakerEmbeddings
    }

    public var result: DiarizationResult {
        DiarizationResult(
            segments: segments.map {
                DiarizedSegment(startTime: $0.start, endTime: $0.end, speakerId: $0.speaker)
            },
            numSpeakers: numSpeakers,
            speakerEmbeddings: speakerEmbeddings)
    }
}
