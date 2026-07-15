import Foundation

/// A transcript library on disk: a folder of Luxicon exports.
///
/// Accepted file shapes (all produced by the app's share actions):
/// - single-session envelope: `{"schemaVersion": 1, "kind": "one-on-one", "transcript": {…}}`
/// - per-person bundle: `{"schemaVersion": 1, "kind": "one-on-one-bundle", "personName": "…", "transcripts": […]}`
/// - a bare `MeetingTranscript` object
///
/// Person attribution, in priority order: the bundle's `personName`, the
/// session title's "1-on-1 with X" suffix, the file's parent folder name.
public struct TranscriptLibrary {
    public struct Session {
        public var person: String
        public var transcript: MeetingTranscript
        public var summary: SessionSummary?
        public var sourceFile: String
    }

    public var sessions: [Session] = []

    public init() {}

    /// People sorted by name, with their sessions oldest→newest.
    public var byPerson: [(person: String, sessions: [Session])] {
        Dictionary(grouping: sessions, by: \.person)
            .map { ($0.key, $0.value.sorted { $0.transcript.date < $1.transcript.date }) }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    public static func load(from directory: URL) -> TranscriptLibrary {
        var library = TranscriptLibrary()
        let files = (FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? [])
            .filter { $0.pathExtension.lowercased() == "json" }

        for file in files {
            guard let data = try? Data(contentsOf: file) else { continue }
            library.sessions.append(contentsOf: parse(
                data,
                sourceFile: file.lastPathComponent,
                folderName: file.deletingLastPathComponent().lastPathComponent == directory.lastPathComponent
                    ? nil
                    : file.deletingLastPathComponent().lastPathComponent
            ))
        }
        library.sessions.sort { $0.transcript.date < $1.transcript.date }
        return library
    }

    static func parse(_ data: Data, sourceFile: String, folderName: String?) -> [Session] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        struct SessionEnvelope: Decodable {
            let kind: String?
            let transcript: MeetingTranscript
            let summary: SessionSummary?

            enum CodingKeys: String, CodingKey { case kind, transcript, summary }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                kind = try c.decodeIfPresent(String.self, forKey: .kind)
                transcript = try c.decode(MeetingTranscript.self, forKey: .transcript)
                // Lenient: a summary from a different app version (schema
                // drift) degrades to nil instead of hiding the whole session
                // — the transcript is the payload, the summary an enrichment.
                summary = try? c.decodeIfPresent(SessionSummary.self, forKey: .summary)
            }
        }
        struct BundleEnvelope: Decodable {
            let kind: String?
            let personName: String
            let transcripts: [MeetingTranscript]
        }

        if let bundle = try? decoder.decode(BundleEnvelope.self, from: data) {
            return bundle.transcripts.map {
                Session(person: bundle.personName, transcript: $0, summary: nil, sourceFile: sourceFile)
            }
        }
        if let envelope = try? decoder.decode(SessionEnvelope.self, from: data) {
            let t = envelope.transcript
            return [Session(person: personName(for: t, folderName: folderName),
                            transcript: t, summary: envelope.summary, sourceFile: sourceFile)]
        }
        if let transcript = try? decoder.decode(MeetingTranscript.self, from: data) {
            return [Session(person: personName(for: transcript, folderName: folderName),
                            transcript: transcript, summary: nil, sourceFile: sourceFile)]
        }
        return []
    }

    static func personName(for transcript: MeetingTranscript, folderName: String?) -> String {
        let title = transcript.title
        for prefix in ["1-on-1 with ", "1:1 with "] {
            if title.hasPrefix(prefix) {
                let name = String(title.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { return name }
            }
        }
        if let folderName, !folderName.isEmpty { return folderName }
        return "Unfiled"
    }

    // MARK: - Queries

    public func sessions(for person: String) -> [Session] {
        sessions
            .filter { $0.person.localizedCaseInsensitiveCompare(person) == .orderedSame }
            .sorted { $0.transcript.date < $1.transcript.date }
    }

    public struct SearchHit {
        public var person: String
        public var sessionDate: Date
        public var turn: TranscriptTurn
        public var context: [TranscriptTurn]
    }

    /// Case-insensitive substring search over turn text, with ±1 turn of context.
    public func search(_ query: String, person: String? = nil, limit: Int = 20) -> [SearchHit] {
        var hits: [SearchHit] = []
        for session in sessions {
            if let person,
               session.person.localizedCaseInsensitiveCompare(person) != .orderedSame {
                continue
            }
            let turns = session.transcript.turns
            for (i, turn) in turns.enumerated()
            where turn.text.localizedCaseInsensitiveContains(query) {
                let lo = max(0, i - 1), hi = min(turns.count - 1, i + 1)
                hits.append(SearchHit(
                    person: session.person,
                    sessionDate: session.transcript.date,
                    turn: turn,
                    context: Array(turns[lo...hi])
                ))
                if hits.count >= limit { return hits }
            }
        }
        return hits
    }

    public struct TrendPoint {
        public var date: Date
        public var duration: Double
        public var personShare: Double?
    }

    /// Per-session talk share for the person across their sessions.
    public func talkTrend(for person: String) -> [TrendPoint] {
        sessions(for: person).map { session in
            let share = session.transcript.speakers
                .first { ($0.speakerName ?? "").localizedCaseInsensitiveCompare(person) == .orderedSame }?
                .talkShare
            return TrendPoint(
                date: session.transcript.date,
                duration: session.transcript.duration,
                personShare: share
            )
        }
    }
}
