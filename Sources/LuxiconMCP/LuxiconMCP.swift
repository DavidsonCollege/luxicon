import Foundation
import MCP
import LuxiconKit

/// MCP server over a local Luxicon transcript library.
///
/// Retrieval only, by design — summarizing and reasoning are the client
/// model's job. The library is re-scanned on every call so freshly exported
/// files appear without a restart.
///
///     luxicon-mcp [--library ~/Luxicon]
///
/// Register with Claude Code:  claude mcp add luxicon -- luxicon-mcp
@main
struct LuxiconMCP {
    static func main() async throws {
        let libraryURL = resolveLibraryURL()
        try? FileManager.default.createDirectory(
            at: libraryURL, withIntermediateDirectories: true)

        if CommandLine.arguments.contains("listen") {
            try SyncListener.run(libraryURL: libraryURL)
        }

        let server = Server(
            name: "luxicon",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: Self.tools)
        }

        await server.withMethodHandler(CallTool.self) { params in
            let library = TranscriptLibrary.load(from: libraryURL)
            do {
                let text = try Self.dispatch(params, library: library, libraryURL: libraryURL)
                return .init(content: [.text(text)], isError: false)
            } catch let error as ToolError {
                return .init(content: [.text(error.message)], isError: true)
            } catch {
                return .init(content: [.text("Error: \(error)")], isError: true)
            }
        }

        let transport = StdioTransport()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }

    static func resolveLibraryURL() -> URL {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--library"), args.indices.contains(i + 1) {
            return URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath)
        }
        if let env = ProcessInfo.processInfo.environment["LUXICON_LIBRARY"] {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Luxicon")
    }

    struct ToolError: Error { let message: String }

    // MARK: - Tool definitions

    static let tools: [Tool] = [
        Tool(
            name: "list_people",
            description: "People with 1-on-1 transcripts in the library, with session counts and date ranges.",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])])
        ),
        Tool(
            name: "list_sessions",
            description: "Sessions for one person: date, duration, talk-time split.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "person": .object(["type": .string("string"), "description": .string("Person name as returned by list_people")]),
                ]),
                "required": .array([.string("person")]),
            ])
        ),
        Tool(
            name: "get_transcript",
            description: "Full speaker-turn transcript of one session, identified by person and ISO date (from list_sessions).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "person": .object(["type": .string("string")]),
                    "date": .object(["type": .string("string"), "description": .string("ISO 8601 date of the session, e.g. 2026-07-08")]),
                ]),
                "required": .array([.string("person"), .string("date")]),
            ])
        ),
        Tool(
            name: "get_summary",
            description: "The on-device generated summary (headline + overview) of one session, when the export included it.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "person": .object(["type": .string("string")]),
                    "date": .object(["type": .string("string"), "description": .string("ISO 8601 date, e.g. 2026-07-08")]),
                ]),
                "required": .array([.string("person"), .string("date")]),
            ])
        ),
        Tool(
            name: "search_transcripts",
            description: "Case-insensitive text search across all transcripts (optionally one person). Returns matching turns with surrounding context.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object(["type": .string("string")]),
                    "person": .object(["type": .string("string"), "description": .string("Optional person filter")]),
                ]),
                "required": .array([.string("query")]),
            ])
        ),
        Tool(
            name: "talk_time_trends",
            description: "Per-session talk-time share for a person across all their sessions — balance of conversation over time.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "person": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("person")]),
            ])
        ),
    ]

    // MARK: - Dispatch

    static func dispatch(
        _ params: CallTool.Parameters,
        library: TranscriptLibrary,
        libraryURL: URL
    ) throws -> String {
        func arg(_ key: String) -> String? {
            params.arguments?[key]?.stringValue
        }
        func require(_ key: String) throws -> String {
            guard let value = arg(key), !value.isEmpty else {
                throw ToolError(message: "Missing required argument '\(key)'.")
            }
            return value
        }

        switch params.name {
        case "list_people":
            let groups = library.byPerson
            guard !groups.isEmpty else {
                return "The library at \(libraryURL.path) is empty. Export sessions from the Luxicon app (per-session JSON or a person's Full History JSON) into that folder."
            }
            return groups.map { person, sessions in
                let dates = sessions.map(\.transcript.date)
                let range = "\(Self.day(dates.first!)) – \(Self.day(dates.last!))"
                return "\(person): \(sessions.count) session(s), \(range)"
            }.joined(separator: "\n")

        case "list_sessions":
            let person = try require("person")
            let sessions = library.sessions(for: person)
            guard !sessions.isEmpty else {
                throw ToolError(message: "No sessions for '\(person)'. Use list_people for available names.")
            }
            return sessions.map { s in
                let split = s.transcript.speakers
                    .map { "\($0.displayName) \(Int(($0.talkShare * 100).rounded()))%" }
                    .joined(separator: ", ")
                return "\(Self.day(s.transcript.date)) — \(TranscriptExport.timestamp(s.transcript.duration)) — \(split)"
            }.joined(separator: "\n")

        case "get_transcript":
            let person = try require("person")
            let date = try require("date")
            // Two 1-on-1s with one person on the same day are rare but real;
            // return every match rather than silently dropping the second.
            let matches = library.sessions(for: person)
                .filter { Self.day($0.transcript.date) == date }
            guard !matches.isEmpty else {
                throw ToolError(message: "No session for '\(person)' on \(date). Use list_sessions for dates.")
            }
            return matches
                .map { TranscriptExport.markdown($0.transcript) }
                .joined(separator: "\n\n---\n\n")

        case "get_summary":
            let person = try require("person")
            let date = try require("date")
            let matches = library.sessions(for: person)
                .filter { Self.day($0.transcript.date) == date }
            guard !matches.isEmpty else {
                throw ToolError(message: "No session for '\(person)' on \(date).")
            }
            return matches.map { session in
                session.summary.map { "\($0.headline)\n\n\($0.overview)" }
                    ?? "No summary in this export. Re-export the session from the app after its summary generates (or use get_transcript and summarize directly)."
            }.joined(separator: "\n\n---\n\n")

        case "search_transcripts":
            let query = try require("query")
            let hits = library.search(query, person: arg("person"))
            guard !hits.isEmpty else { return "No matches for \"\(query)\"." }
            return hits.map { hit in
                let context = hit.context
                    .map { "  \($0.displayName): \($0.text)" }
                    .joined(separator: "\n")
                return "\(hit.person), \(Self.day(hit.sessionDate)) at \(TranscriptExport.timestamp(hit.turn.start)):\n\(context)"
            }.joined(separator: "\n\n")

        case "talk_time_trends":
            let person = try require("person")
            let trend = library.talkTrend(for: person)
            guard !trend.isEmpty else {
                throw ToolError(message: "No sessions for '\(person)'.")
            }
            return trend.map { point in
                let share = point.personShare.map { "\(Int(($0 * 100).rounded()))%" } ?? "n/a"
                return "\(Self.day(point.date)): \(person) spoke \(share) of \(TranscriptExport.timestamp(point.duration))"
            }.joined(separator: "\n")

        default:
            throw ToolError(message: "Unknown tool '\(params.name)'.")
        }
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}
