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

/// A parsed people file: the roster plus the optional top-level "me" entry —
/// background about the user themself ("about me") that imports route to
/// My Voice rather than the roster.
public struct PeopleFile: Sendable, Equatable {
    /// Context for the user themself, from the top-level "me" entry.
    public var myContext: String?
    public var people: [PersonImport]

    public init(myContext: String? = nil, people: [PersonImport]) {
        self.myContext = myContext
        self.people = people
    }
}

/// JSON exchange format for the people roster — the shape an AI agent or a
/// web service should produce:
///
/// ```json
/// {
///   "kind": "luxicon-people",
///   "schemaVersion": 1,
///   "me": {"name": "Alex Kim", "context": "Director of infrastructure; leads the platform team"},
///   "people": [
///     {"name": "Priya Patel", "context": "Senior sysadmin; runs identity platform"}
///   ]
/// }
/// ```
///
/// Parsing is deliberately liberal: a bare array works, entries may be plain
/// strings (name only), "me" may be a bare context string, and unknown fields
/// are ignored. Importing merges by name and never deletes — see
/// `Store.importPeople`.
public enum PeopleJSON {

    public static func export(_ people: [PersonImport], me: PersonImport? = nil) throws -> Data {
        try envelope(people: people, me: me, instructions: nil)
    }

    /// Starter file with inline instructions for whoever (or whatever) fills it in.
    public static func template(existing: [PersonImport], me: PersonImport? = nil) throws -> Data {
        try envelope(
            people: existing,
            me: me,
            instructions: """
            Add one object per person to "people". Fields: name (required — \
            as it should appear in transcripts, e.g. "Priya Patel"); context \
            (background that helps meeting summaries: role, projects, current \
            threads). The top-level "me" is the app's user: its context is \
            about-me background in the same style, imported into My Voice \
            instead of the roster. Importing adds new people and updates \
            context on matching names; it never removes anyone.
            """
        )
    }

    /// A ready-to-paste prompt for an AI assistant that produces an
    /// importable roster file, with the current people embedded so the
    /// agent extends rather than starts over.
    public static func agentPrompt(existing: [PersonImport], me: PersonImport? = nil) -> String {
        let current: String
        if existing.isEmpty && me?.context == nil {
            current = "(none yet)"
        } else {
            current = (try? export(existing, me: me)).flatMap { String(data: $0, encoding: .utf8) }
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
          "me": {"name": "Alex Kim", "context": "Director of infrastructure; leads the platform team; hiring two sysadmins this quarter"},
          "people": [
            {"name": "Priya Patel", "context": "Senior sysadmin; runs the identity platform; discussing promotion this quarter"}
          ]
        }

        Rules:
        - "name": the person's name exactly as it should appear in transcripts.
        - "me": that's me, the user — background about myself in the same \
        style (role, team, current priorities). It is imported as my own \
        about-me context, not as a roster entry.
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

    public static func parse(_ data: Data) throws -> PeopleFile {
        let root = try JSONSerialization.jsonObject(with: data)
        var myContext: String?
        let rawPeople: [Any]
        if let envelope = root as? [String: Any] {
            myContext = meContext(from: envelope["me"])
            if let people = envelope["people"] as? [Any] {
                rawPeople = people
            } else if myContext != nil {
                rawPeople = []
            } else {
                throw ParseError.missingPeople
            }
        } else if let array = root as? [Any] {
            rawPeople = array
        } else {
            throw ParseError.missingPeople
        }

        let records = rawPeople.compactMap(record(from:))
        guard !records.isEmpty || myContext != nil else { throw ParseError.noEntries }
        return PeopleFile(myContext: myContext, people: records)
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

    /// The "me" entry is liberal too: an object with a context, or a bare
    /// context string. Its name is informational (who "me" is, for agents).
    private static func meContext(from raw: Any?) -> String? {
        if let s = raw as? String { return nonEmpty(s) }
        if let dict = raw as? [String: Any] { return nonEmpty(dict["context"] as? String) }
        return nil
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    private static func envelope(people: [PersonImport], me: PersonImport?, instructions: String?) throws -> Data {
        var root: [String: Any] = [
            "kind": "luxicon-people",
            "schemaVersion": 1,
            "people": people.map { person -> [String: Any] in
                var obj: [String: Any] = ["name": person.name]
                if let context = person.context { obj["context"] = context }
                return obj
            },
        ]
        if let me {
            var obj: [String: Any] = ["name": me.name]
            if let context = me.context { obj["context"] = context }
            root["me"] = obj
        }
        if let instructions { root["instructions"] = instructions }
        return try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }
}
