import Foundation

/// JSON exchange format for vocabulary — the shape an AI agent or a web
/// service should produce:
///
/// ```json
/// {
///   "kind": "luxicon-vocabulary",
///   "schemaVersion": 1,
///   "terms": [
///     {"term": "Choreo", "soundsLike": ["corio"], "category": "project", "notes": "…"}
///   ]
/// }
/// ```
///
/// Parsing is deliberately liberal: a bare array works, entries may be plain
/// strings, and `sounds_like` snake_case keys are accepted alongside
/// `soundsLike`. Unknown fields are ignored.
public enum VocabularyJSON {

    public static func export(_ entries: [VocabularyEntry]) throws -> Data {
        try envelope(entries: entries, instructions: nil)
    }

    /// Starter file with inline instructions for whoever (or whatever) fills it in.
    public static func template(existing: [VocabularyEntry]) throws -> Data {
        try envelope(
            entries: existing,
            instructions: """
            Add one object per term to "terms". Fields: term (required — the \
            canonical spelling, e.g. "Choreo"); soundsLike (array of likely \
            speech-to-text mishearings, e.g. ["corio", "correo"]); category \
            (one of name, project, acronym, place, other); notes (context for \
            humans/agents — the app ignores it). Example: {"term": "Priya \
            Patel", "soundsLike": ["pria patel"], "category": "name"}.
            """
        )
    }

    /// A ready-to-paste prompt for an AI assistant that produces an
    /// importable vocabulary file, with the user's current terms embedded so
    /// the agent extends rather than starts over.
    public static func agentPrompt(existing: [VocabularyEntry]) -> String {
        let current: String
        if existing.isEmpty {
            current = "(none yet)"
        } else {
            current = (try? export(existing)).flatMap { String(data: $0, encoding: .utf8) }
                ?? "(none yet)"
        }
        return """
        Help me improve on-device speech-to-text for my 1-on-1 meeting recorder \
        (Luxicon). Build a vocabulary file that grounds transcription in the \
        words my meetings actually contain.

        Output valid JSON only, in exactly this format:

        {
          "kind": "luxicon-vocabulary",
          "schemaVersion": 1,
          "terms": [
            {"term": "Choreo", "soundsLike": ["corio", "correo"], "category": "project", "notes": "internal platform"}
          ]
        }

        Rules:
        - "term": the canonical spelling, exactly as it should appear in transcripts.
        - "soundsLike": up to 3 plausible speech-to-text mishearings — phonetically \
        similar words or spellings a recognizer might produce instead. Omit when \
        the term is unlikely to be misheard. NEVER use a common English word as a \
        soundsLike entry ("this", "have", "will", "quality"): these are replaced \
        everywhere they appear, so one common-word alias rewrites the whole \
        transcript. Prefer non-word spellings ("furpa", "empsy") or multi-word \
        phrases ("heck vat"); a real word is acceptable only when it is rare in \
        workplace speech ("cattle").
        - "category": one of name, project, acronym, place, other.
        - "notes": brief context for future maintenance (the app ignores it).
        - Include: names of people I work with, project and system names, \
        acronyms, organization-specific jargon, and local place names. Exclude \
        ordinary English words — the recognizer already knows them.
        - 20-60 terms is the useful range; quality over quantity.

        If I haven't provided source material, ask me for a team roster, project \
        list, or glossary/wiki pages before guessing.

        My current vocabulary — extend and improve it, keeping existing terms \
        unless they are clearly wrong:

        \(current)

        Return only the finished JSON, ready to import.
        """
    }

    public static func parse(_ data: Data) throws -> [VocabularyEntry] {
        let root = try JSONSerialization.jsonObject(with: data)
        let rawTerms: [Any]
        if let envelope = root as? [String: Any] {
            guard let terms = envelope["terms"] as? [Any] else {
                throw ParseError.missingTerms
            }
            rawTerms = terms
        } else if let array = root as? [Any] {
            rawTerms = array
        } else {
            throw ParseError.missingTerms
        }

        let entries = rawTerms.compactMap(entry(from:))
        guard !entries.isEmpty else { throw ParseError.noEntries }
        return entries
    }

    public enum ParseError: Error, LocalizedError {
        case missingTerms
        case noEntries

        public var errorDescription: String? {
            switch self {
            case .missingTerms:
                return "Expected a JSON object with a \"terms\" array (or a bare array of terms)."
            case .noEntries:
                return "No vocabulary terms found in the file."
            }
        }
    }

    // MARK: - Internals

    private static func entry(from raw: Any) -> VocabularyEntry? {
        if let term = raw as? String {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : VocabularyEntry(term: trimmed)
        }
        guard let dict = raw as? [String: Any],
              let term = (dict["term"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !term.isEmpty else { return nil }
        let soundsLike = (dict["soundsLike"] ?? dict["sounds_like"]) as? [Any] ?? []
        return VocabularyEntry(
            term: term,
            soundsLike: soundsLike.compactMap { ($0 as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            category: nonEmpty(dict["category"] as? String),
            notes: nonEmpty(dict["notes"] as? String)
        )
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    private static func envelope(entries: [VocabularyEntry], instructions: String?) throws -> Data {
        var root: [String: Any] = [
            "kind": "luxicon-vocabulary",
            "schemaVersion": 1,
            "terms": entries.map { entry -> [String: Any] in
                var obj: [String: Any] = ["term": entry.term]
                if !entry.soundsLike.isEmpty { obj["soundsLike"] = entry.soundsLike }
                if let category = entry.category { obj["category"] = category }
                if let notes = entry.notes { obj["notes"] = notes }
                return obj
            },
        ]
        if let instructions { root["instructions"] = instructions }
        return try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }
}
