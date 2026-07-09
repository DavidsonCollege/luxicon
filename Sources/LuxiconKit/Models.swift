import Foundation

// MARK: - Transcript types

/// One speaker turn in a diarized transcript.
public struct TranscriptTurn: Codable, Sendable, Identifiable, Equatable {
    public var id: Int
    /// Diarization speaker index (0-based).
    public var speakerId: Int
    /// Resolved display name ("Alice") if enrollment matched or the user labeled it.
    public var speakerName: String?
    /// Start time in seconds from the beginning of the recording.
    public var start: Double
    /// End time in seconds.
    public var end: Double
    public var text: String
    /// ASR confidence 0–1 (0 if the engine doesn't report one).
    public var confidence: Float

    public var duration: Double { end - start }

    public init(
        id: Int, speakerId: Int, speakerName: String? = nil,
        start: Double, end: Double, text: String, confidence: Float = 0
    ) {
        self.id = id
        self.speakerId = speakerId
        self.speakerName = speakerName
        self.start = start
        self.end = end
        self.text = text
        self.confidence = confidence
    }

    /// Label to render: name if known, otherwise "Speaker N".
    public var displayName: String { speakerName ?? "Speaker \(speakerId + 1)" }
}

/// Per-speaker aggregate statistics.
public struct SpeakerStats: Codable, Sendable, Equatable {
    public var speakerId: Int
    public var speakerName: String?
    /// Total seconds of speech attributed to this speaker.
    public var speakingTime: Double
    /// Share of total speech time, 0–1.
    public var talkShare: Double
    public var turnCount: Int
    /// Duration in seconds of this speaker's longest uninterrupted turn.
    public var longestTurn: Double

    public var displayName: String { speakerName ?? "Speaker \(speakerId + 1)" }
}

/// A fully processed meeting.
public struct MeetingTranscript: Codable, Sendable, Equatable {
    public var title: String
    public var date: Date
    /// Recording length in seconds.
    public var duration: Double
    public var turns: [TranscriptTurn]
    public var speakers: [SpeakerStats]

    public init(title: String, date: Date, duration: Double, turns: [TranscriptTurn]) {
        self.title = title
        self.date = date
        self.duration = duration
        self.turns = turns
        self.speakers = Self.computeStats(turns: turns)
    }

    public static func computeStats(turns: [TranscriptTurn]) -> [SpeakerStats] {
        let totalSpeech = turns.reduce(0) { $0 + $1.duration }
        let bySpeaker = Dictionary(grouping: turns, by: \.speakerId)
        return bySpeaker.keys.sorted().map { id in
            let ts = bySpeaker[id]!
            let time = ts.reduce(0) { $0 + $1.duration }
            return SpeakerStats(
                speakerId: id,
                speakerName: ts.first?.speakerName,
                speakingTime: time,
                talkShare: totalSpeech > 0 ? time / totalSpeech : 0,
                turnCount: ts.count,
                longestTurn: ts.map(\.duration).max() ?? 0
            )
        }
    }

    /// Rename a diarization speaker everywhere (turns + stats).
    public mutating func setName(_ name: String, forSpeaker speakerId: Int) {
        for i in turns.indices where turns[i].speakerId == speakerId {
            turns[i].speakerName = name
        }
        for i in speakers.indices where speakers[i].speakerId == speakerId {
            speakers[i].speakerName = name
        }
    }
}

// MARK: - Enrollment

/// A known voice: a person with a stored speaker embedding.
public struct VoiceEnrollment: Codable, Sendable, Equatable {
    public var name: String
    /// 256-dim L2-normalized WeSpeaker embedding.
    public var embedding: [Float]

    public init(name: String, embedding: [Float]) {
        self.name = name
        self.embedding = embedding
    }
}

/// Cosine similarity of two L2-normalized embeddings (dot product).
public func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    return zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
}
