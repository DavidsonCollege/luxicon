import Foundation
import LuxiconKit
import os

/// Mac sessions in the shared `~/Luxicon` library.
///
/// The library also holds the phone's pushed files, which the Mac does not
/// own. The rule everything here follows: the Mac overwrites, renames, or
/// deletes a library file only when that file's envelope says
/// `"source": "mac"` with this session's id. Anything else at a name the Mac
/// wants is left byte-for-byte alone, and the Mac writes beside it instead.
extension Store {
    private static let libraryLog = Logger(subsystem: "edu.davidson.luxicon.mac", category: "library")

    /// Write (or rewrite) a finished session's export envelope into the
    /// library. No-op unless the session is `.ready` with a transcript.
    /// Called from `update(_:)`, so it must never call `update` itself.
    func writeLibraryFile(for session: SessionRecord) {
        // Work from the stored record: callers' copies can be stale.
        guard let i = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        let session = sessions[i]
        guard session.status == .ready, let transcript = session.transcript else { return }

        let dir = LibraryLocation.url
        // The folder may have been removed while the app was running.
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data: Data
        do {
            data = try TranscriptExport.json(
                transcript, summary: session.summary,
                sessionId: session.id, source: TranscriptExport.macSource)
        } catch {
            reportLibraryError("Could not encode the session for ~/Luxicon: \(error.localizedDescription)")
            return
        }

        let base = libraryBaseFilename(for: session)
        guard let name = Self.libraryCandidates(base: base).first(where: {
            Self.isFree(dir.appendingPathComponent($0), for: session.id)
        }) else {
            reportLibraryError("Could not save to ~/Luxicon: other files already use the name \(base).")
            return
        }

        let url = dir.appendingPathComponent(name)
        // Skip identical rewrites (most update() calls don't touch the
        // transcript or summary), so the folder watcher stays quiet.
        if (try? Data(contentsOf: url)) != data {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                reportLibraryError("Could not save to ~/Luxicon: \(error.localizedDescription)")
                return
            }
        }

        // Name changed (person renamed, or a collision appeared or cleared):
        // drop the old file, but only if it is still this session's.
        if let old = session.libraryFileName, old != name {
            let oldURL = dir.appendingPathComponent(old)
            if Self.isOwned(oldURL, by: session.id) {
                try? FileManager.default.removeItem(at: oldURL)
            }
        }
        // Set directly: going through update() would recurse back here.
        if sessions[i].libraryFileName != name {
            sessions[i].libraryFileName = name
            save()
        }
        libraryError = nil
    }

    /// Remove a session's library file(s). Only files the Mac wrote for this
    /// session are touched.
    func deleteLibraryFile(for session: SessionRecord) {
        let stored = sessions.first { $0.id == session.id } ?? session
        let dir = LibraryLocation.url
        // The recorded name, plus every name it could have used, in case the
        // record never got to store it (e.g. a save failed after the write).
        var names = Self.libraryCandidates(base: libraryBaseFilename(for: stored))
        if let recorded = stored.libraryFileName { names.insert(recorded, at: 0) }
        for name in Set(names) {
            let url = dir.appendingPathComponent(name)
            if Self.isOwned(url, by: stored.id) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Remove a Mac-recorded library file whose store record is gone (an
    /// orphan). Ownership-gated like every other removal: the file must say
    /// `"source": "mac"` with the session's own id.
    func deleteOrphanLibraryFile(_ session: TranscriptLibrary.Session) {
        guard session.source == TranscriptExport.macSource, let id = session.sessionId,
              session.bundleIndex == nil else { return }
        // relativePath reaches files in subfolders too; isOwned still gates it.
        let url = LibraryLocation.url.appendingPathComponent(session.relativePath)
        if Self.isOwned(url, by: id) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Rename a person and move their finished sessions' library files to
    /// the new name right away. Session titles that follow the default
    /// "1-on-1 with <name>" pattern follow the rename, since the library
    /// (and MCP) attribute sessions by that title.
    func renamePerson(id: UUID, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let p = people.firstIndex(where: { $0.id == id }) else { return }
        let oldName = people[p].name
        guard name != oldName else { return }
        people[p].name = name
        let oldTitle = "1-on-1 with \(oldName)", newTitle = "1-on-1 with \(name)"
        for i in sessions.indices where sessions[i].personId == id {
            if sessions[i].title == oldTitle { sessions[i].title = newTitle }
            if sessions[i].transcript?.title == oldTitle { sessions[i].transcript?.title = newTitle }
        }
        save()
        for session in sessions where session.personId == id && session.status == .ready {
            writeLibraryFile(for: session)
        }
    }

    // MARK: - Helpers

    private func libraryBaseFilename(for session: SessionRecord) -> String {
        LuxiconSync.sessionFilename(
            person: person(id: session.personId)?.name ?? "session",
            date: session.date, id: session.id)
    }

    /// The phone's name for the session first, then ` (Mac)` variants for
    /// when a file the Mac doesn't own already sits there.
    private static func libraryCandidates(base: String) -> [String] {
        let stem = base.hasSuffix(".json") ? String(base.dropLast(5)) : base
        return [base, "\(stem) (Mac).json"] + (2...20).map { "\(stem) (Mac \($0)).json" }
    }

    /// Nothing at `url`, or a file this session already owns.
    private static func isFree(_ url: URL, for id: UUID) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if !exists {
            // fileExists follows symlinks; never write over a dangling one.
            return (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil
        }
        return !isDirectory.boolValue && isOwned(url, by: id)
    }

    /// True only for a readable envelope with `"source": "mac"` and this
    /// session's id. Unreadable, unparseable, phone, and other-session
    /// files are never ours.
    private static func isOwned(_ url: URL, by id: UUID) -> Bool {
        struct Provenance: Decodable {
            let sessionId: UUID?
            let source: String?
        }
        guard let data = try? Data(contentsOf: url),
              let provenance = try? JSONDecoder().decode(Provenance.self, from: data) else { return false }
        return provenance.source == TranscriptExport.macSource && provenance.sessionId == id
    }

    private func reportLibraryError(_ message: String) {
        Self.libraryLog.error("\(message, privacy: .public)")
        libraryError = message
    }
}
