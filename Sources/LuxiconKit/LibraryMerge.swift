import Foundation

/// Pure helpers for reconciling the shared `~/Luxicon` library with the
/// sessions the Mac app owns in its own store.
public enum LibraryMerge {
    /// Library sessions that came from the iPhone: everything except sessions
    /// the Mac app owns and Mac-sourced orphans (see `orphanMacSessions`).
    public static func phoneSessions(
        _ all: [TranscriptLibrary.Session], ownedIds: Set<UUID>
    ) -> [TranscriptLibrary.Session] {
        all.filter { session in
            if let id = session.sessionId, ownedIds.contains(id) { return false }
            return session.source != TranscriptExport.macSource
        }
    }

    /// Mac-recorded sessions found in the library that the Mac store no
    /// longer owns (e.g. after a reinstall).
    public static func orphanMacSessions(
        _ all: [TranscriptLibrary.Session], ownedIds: Set<UUID>
    ) -> [TranscriptLibrary.Session] {
        all.filter { session in
            guard session.source == TranscriptExport.macSource else { return false }
            guard let id = session.sessionId else { return true }
            return !ownedIds.contains(id)
        }
    }

    /// People present in the library but unknown to the app, sorted.
    public static func libraryOnlyNames(
        _ sessions: [TranscriptLibrary.Session], knownNames: [String]
    ) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for session in sessions where session.person != "Unfiled" {
            let key = session.person.lowercased()
            if knownNames.contains(where: { $0.localizedCaseInsensitiveCompare(session.person) == .orderedSame }) { continue }
            if seen.insert(key).inserted { out.append(session.person) }
        }
        return out.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
