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
/// The file-level checks live (and are tested) in LuxiconKit's `LibraryFiles`.
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
            reportLibraryError("Could not encode the session for ~/Luxicon: \(error.localizedDescription)",
                               for: session.id)
            return
        }

        let base = libraryBaseFilename(for: session)
        guard let name = LibraryFiles.freeName(base: base, in: dir, for: session.id) else {
            reportLibraryError("Other files in ~/Luxicon already use the name \(base) and its variants.",
                               for: session.id)
            return
        }

        let url = dir.appendingPathComponent(name)
        // Skip identical rewrites (most update() calls don't touch the
        // transcript or summary), so the folder watcher stays quiet.
        if (try? Data(contentsOf: url)) != data {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                reportLibraryError(error.localizedDescription, for: session.id)
                return
            }
        }

        // Name changed (person renamed, or a collision appeared or cleared):
        // drop the old file, but only if it is still this session's.
        if let old = session.libraryFileName, old != name {
            let oldURL = dir.appendingPathComponent(old)
            if LibraryFiles.isOwned(oldURL, by: session.id) {
                try? FileManager.default.removeItem(at: oldURL)
            }
        }
        // Set directly: going through update() would recurse back here.
        if sessions[i].libraryFileName != name {
            sessions[i].libraryFileName = name
            save()
        }
        if libraryWriteErrors[session.id] != nil {
            libraryWriteErrors[session.id] = nil
            #if DEBUG
            DebugLaunchOptions.log("library write recovered for \(session.id.uuidString): \(name)")
            #endif
        }
    }

    /// Write again every finished session whose library file failed to
    /// write, is missing (deleted, or ~/Luxicon itself removed), or sits
    /// under a name it shouldn't (e.g. a rename whose move failed). Run at
    /// launch and whenever the app becomes active. Unchanged files are not
    /// rewritten (see `writeLibraryFile`), so this is cheap when all is well.
    func retryLibraryWrites() {
        let dir = LibraryLocation.url
        for session in sessions where session.status == .ready && session.transcript != nil {
            let needsWrite: Bool
            if libraryWriteErrors[session.id] != nil {
                needsWrite = true
            } else if let name = session.libraryFileName {
                let onDisk = FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
                let expected = LibraryFiles.candidates(base: libraryBaseFilename(for: session)).contains(name)
                needsWrite = !onDisk || !expected
            } else {
                needsWrite = true
            }
            if needsWrite { writeLibraryFile(for: session) }
        }
    }

    /// Remove a session's library file(s). Only files the Mac wrote for this
    /// session are touched.
    func deleteLibraryFile(for session: SessionRecord) {
        let stored = sessions.first { $0.id == session.id } ?? session
        let dir = LibraryLocation.url
        // The recorded name, plus every name it could have used, in case the
        // record never got to store it (e.g. a save failed after the write).
        var names = LibraryFiles.candidates(base: libraryBaseFilename(for: stored))
        if let recorded = stored.libraryFileName { names.insert(recorded, at: 0) }
        for name in Set(names) {
            let url = dir.appendingPathComponent(name)
            if LibraryFiles.isOwned(url, by: stored.id) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        libraryWriteErrors[stored.id] = nil
    }

    /// Remove a Mac-recorded library file whose store record is gone (an
    /// orphan). Ownership-gated like every other removal: the file must say
    /// `"source": "mac"` with the session's own id.
    func deleteOrphanLibraryFile(_ session: TranscriptLibrary.Session) {
        guard session.source == TranscriptExport.macSource, let id = session.sessionId,
              session.bundleIndex == nil else { return }
        // relativePath reaches files in subfolders too; isOwned still gates it.
        let url = LibraryLocation.url.appendingPathComponent(session.relativePath)
        if LibraryFiles.isOwned(url, by: id) {
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

    private func reportLibraryError(_ message: String, for id: UUID) {
        Self.libraryLog.error("library write failed for \(id.uuidString, privacy: .public): \(message, privacy: .public)")
        libraryWriteErrors[id] = message
        #if DEBUG
        DebugLaunchOptions.log("library write failed for \(id.uuidString): \(message)")
        #endif
    }
}
