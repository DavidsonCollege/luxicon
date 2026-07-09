import Foundation

/// Export formats designed to be pasted into (or read by) an AI assistant.
public enum TranscriptExport {
    /// Human-readable markdown with metadata header, talk-time stats, and
    /// timestamped speaker turns.
    public static func markdown(_ t: MeetingTranscript) -> String {
        var out = "# 1-on-1: \(t.title)\n\n"
        out += "- **Date:** \(t.date.formatted(date: .long, time: .shortened))\n"
        out += "- **Duration:** \(timestamp(t.duration))\n"
        out += "- **Participants:** "
        out += t.speakers.map {
            "\($0.displayName) (\(Int(($0.talkShare * 100).rounded()))% talk time, \($0.turnCount) turns)"
        }.joined(separator: ", ")
        out += "\n\n## Transcript\n\n"
        for turn in t.turns {
            out += "**[\(timestamp(turn.start))] \(turn.displayName):** \(turn.text)\n\n"
        }
        return out
    }

    /// Structured JSON (stable schema, `schemaVersion` field) for programmatic
    /// AI consumption — e.g. an MCP server or batch analysis.
    public static func json(_ t: MeetingTranscript) throws -> Data {
        struct Envelope: Encodable {
            let schemaVersion = 1
            let kind = "one-on-one"
            let transcript: MeetingTranscript
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Envelope(transcript: t))
    }

    /// mm:ss (or h:mm:ss past an hour).
    public static func timestamp(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
