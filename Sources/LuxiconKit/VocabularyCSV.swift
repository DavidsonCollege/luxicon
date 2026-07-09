import Foundation

/// CSV exchange format for vocabulary, designed so an AI agent (or a
/// spreadsheet) can fill it out on the user's behalf and hand it back.
///
/// Columns:
/// - `term` — canonical spelling (required)
/// - `sounds_like` — semicolon-separated known ASR mishearings
/// - `category` — name | project | acronym | place | other
/// - `notes` — free text, ignored by the app
///
/// Rows whose term starts with `#` are treated as comments and skipped on
/// import, which lets the template carry instructions and examples.
public enum VocabularyCSV {
    public static let header = "term,sounds_like,category,notes"

    /// A starter file: instructions, worked examples, then current entries.
    public static func template(existing: [VocabularyEntry]) -> String {
        var rows = [header]
        rows.append(row(VocabularyEntry(
            term: "# Rows starting with # are ignored. Fill one row per term; sounds_like is semicolon-separated mishearings.")))
        rows.append(row(VocabularyEntry(
            term: "# Example -> Choreo", soundsLike: ["corio", "correo"],
            category: "project", notes: "Internal platform framework")))
        rows.append(row(VocabularyEntry(
            term: "# Example -> Priya Patel", soundsLike: ["pria patel"],
            category: "name", notes: "Data engineering lead")))
        rows.append(contentsOf: existing.map(row))
        return rows.joined(separator: "\n") + "\n"
    }

    public static func export(_ entries: [VocabularyEntry]) -> String {
        ([header] + entries.map(row)).joined(separator: "\n") + "\n"
    }

    /// Parse a completed CSV. Header and `#` rows are skipped; blank terms
    /// are dropped. Throws only when the file contains no usable rows.
    public static func parse(_ csv: String) throws -> [VocabularyEntry] {
        let records = parseRecords(csv)
        var entries: [VocabularyEntry] = []
        for fields in records {
            guard let term = fields.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !term.isEmpty,
                  !term.hasPrefix("#"),
                  term.lowercased() != "term" else { continue }
            let soundsLike = (fields.count > 1 ? fields[1] : "")
                .split(separator: ";")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let category = fields.count > 2 ? nonEmpty(fields[2]) : nil
            let notes = fields.count > 3 ? nonEmpty(fields[3]) : nil
            entries.append(VocabularyEntry(
                term: term, soundsLike: soundsLike, category: category, notes: notes))
        }
        guard !entries.isEmpty else {
            throw ParseError.noEntries
        }
        return entries
    }

    public enum ParseError: Error, LocalizedError {
        case noEntries
        public var errorDescription: String? {
            "No vocabulary rows found. Expected a CSV with a 'term' column."
        }
    }

    // MARK: - Internals

    private static func nonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func row(_ e: VocabularyEntry) -> String {
        [e.term, e.soundsLike.joined(separator: "; "), e.category ?? "", e.notes ?? ""]
            .map(escape)
            .joined(separator: ",")
    }

    private static func escape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    /// Minimal RFC 4180 reader: quoted fields, escaped quotes, CRLF/LF.
    static func parseRecords(_ csv: String) -> [[String]] {
        var records: [[String]] = []
        var fields: [String] = []
        var field = ""
        var inQuotes = false
        var i = csv.startIndex

        func endField() { fields.append(field); field = "" }
        func endRecord() {
            endField()
            if !(fields.count == 1 && fields[0].isEmpty) { records.append(fields) }
            fields = []
        }

        while i < csv.endIndex {
            let c = csv[i]
            if inQuotes {
                if c == "\"" {
                    let next = csv.index(after: i)
                    if next < csv.endIndex, csv[next] == "\"" {
                        field.append("\""); i = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": endField()
                case "\r": break
                case "\n": endRecord()
                default: field.append(c)
                }
            }
            i = csv.index(after: i)
        }
        if !field.isEmpty || !fields.isEmpty { endRecord() }
        return records
    }
}
