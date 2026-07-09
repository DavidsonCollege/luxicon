import Foundation

/// One roster record in the people exchange format — the Kit-level shape;
/// the app maps it onto its own `Person` (which also owns photos/sessions).
public struct PersonImport: Codable, Sendable, Equatable {
    public var name: String
    /// Background for the summarizer: role, projects, current threads.
    public var context: String?

    public init(name: String, context: String? = nil) {
        self.name = name
        self.context = context
    }
}

/// JSON exchange format for the people roster — the shape an AI agent or a
/// web service should produce:
///
/// ```json
/// {
///   "kind": "luxicon-people",
///   "schemaVersion": 1,
///   "people": [
///     {"name": "Priya Patel", "context": "Senior sysadmin; runs identity platform"}
///   ]
/// }
/// ```
///
/// Parsing is deliberately liberal: a bare array works, entries may be plain
/// strings (name only), and unknown fields are ignored. Importing merges by
/// name and never deletes — see `Store.importPeople`.
public enum PeopleJSON {

    public static func export(_ people: [PersonImport]) throws -> Data {
        try envelope(people: people, instructions: nil)
    }

    /// Starter file with inline instructions for whoever (or whatever) fills it in.
    public static func template(existing: [PersonImport]) throws -> Data {
        try envelope(
            people: existing,
            instructions: """
            Add one object per person to "people". Fields: name (required — \
            as it should appear in transcripts, e.g. "Priya Patel"); context \
            (background that helps meeting summaries: role, projects, current \
            threads). Importing adds new people and updates context on \
            matching names; it never removes anyone.
            """
        )
    }

    /// A ready-to-paste prompt for an AI assistant that produces an
    /// importable roster file, with the current people embedded so the
    /// agent extends rather than starts over.
    public static func agentPrompt(existing: [PersonImport]) -> String {
        let current: String
        if existing.isEmpty {
            current = "(none yet)"
        } else {
            current = (try? export(existing)).flatMap { String(data: $0, encoding: .utf8) }
                ?? "(none yet)"
        }
        return """
        Help me maintain the roster for my 1-on-1 meeting recorder (Luxicon). \
        Build a people file listing everyone I hold 1-on-1s with, plus \
        background context that helps an on-device model summarize our \
        meetings.

        Output valid JSON only, in exactly this format:

        {
          "kind": "luxicon-people",
          "schemaVersion": 1,
          "people": [
            {"name": "Priya Patel", "context": "Senior sysadmin; runs the identity platform; discussing promotion this quarter"}
          ]
        }

        Rules:
        - "name": the person's name exactly as it should appear in transcripts.
        - "context": 2-3 paragraphs of background, written for a summarizer \
        that has never met them. Cover their role, team, and seniority; the \
        projects and systems they own or work on, using the names likely to \
        come up in conversation; and what is currently live between us — \
        goals, open challenges, recurring 1-on-1 threads, career-development \
        topics, and anything recently shipped, decided, or escalated.
        - Write context as plain prose paragraphs (separated by blank lines \
        inside the JSON string), not bullet fragments — the summarizer reads \
        it as narrative background. The example above is abbreviated; real \
        entries should be much fuller.
        - Importing merges by name and never removes anyone, so include only \
        people to add or update.

        If I haven't provided source material, ask me before guessing: a team \
        roster or org chart, recent project updates or status notes, and \
        anything else you need per person — thin context produces thin \
        summaries.

        My current people — extend and improve, keeping existing entries \
        unless they are clearly wrong:

        \(current)

        Return only the finished JSON, ready to import.
        """
    }

    public static func parse(_ data: Data) throws -> [PersonImport] {
        let root = try JSONSerialization.jsonObject(with: data)
        let rawPeople: [Any]
        if let envelope = root as? [String: Any] {
            guard let people = envelope["people"] as? [Any] else {
                throw ParseError.missingPeople
            }
            rawPeople = people
        } else if let array = root as? [Any] {
            rawPeople = array
        } else {
            throw ParseError.missingPeople
        }

        let records = rawPeople.compactMap(record(from:))
        guard !records.isEmpty else { throw ParseError.noEntries }
        return records
    }

    public enum ParseError: Error, LocalizedError {
        case missingPeople
        case noEntries

        public var errorDescription: String? {
            switch self {
            case .missingPeople:
                return "Expected a JSON object with a \"people\" array (or a bare array of people)."
            case .noEntries:
                return "No people found in the file."
            }
        }
    }

    // MARK: - Internals

    private static func record(from raw: Any) -> PersonImport? {
        if let name = raw as? String {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : PersonImport(name: trimmed)
        }
        guard let dict = raw as? [String: Any],
              let name = (dict["name"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return PersonImport(name: name, context: nonEmpty(dict["context"] as? String))
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    private static func envelope(people: [PersonImport], instructions: String?) throws -> Data {
        var root: [String: Any] = [
            "kind": "luxicon-people",
            "schemaVersion": 1,
            "people": people.map { person -> [String: Any] in
                var obj: [String: Any] = ["name": person.name]
                if let context = person.context { obj["context"] = context }
                return obj
            },
        ]
        if let instructions { root["instructions"] = instructions }
        return try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }
}
