import Foundation

/// File-level ownership rules for the Mac app's writes into the shared
/// `~/Luxicon` library, which also holds the phone's pushed files.
///
/// The rule: the Mac overwrites, renames, or deletes a library file only when
/// that file's envelope says `"source": "mac"` (`TranscriptExport.macSource`)
/// with the session's own id. Anything else at a name the Mac wants is left
/// byte-for-byte alone, and the Mac writes beside it instead.
public enum LibraryFiles {
    /// Names a session may use, in order of preference: the phone's name for
    /// the session (`LuxiconSync.sessionFilename`) first, then ` (Mac)`
    /// variants for when a file the Mac doesn't own already sits there.
    public static func candidates(base: String) -> [String] {
        let stem = base.hasSuffix(".json") ? String(base.dropLast(5)) : base
        return [base, "\(stem) (Mac).json"] + (2...20).map { "\(stem) (Mac \($0)).json" }
    }

    /// True only for a readable envelope with `"source": "mac"` and this
    /// session's id. Unreadable, unparseable, phone, and other-session files
    /// are never the Mac's.
    public static func isOwned(_ url: URL, by id: UUID) -> Bool {
        struct Provenance: Decodable {
            let sessionId: UUID?
            let source: String?
        }
        guard let data = try? Data(contentsOf: url),
              let provenance = try? JSONDecoder().decode(Provenance.self, from: data) else { return false }
        return provenance.source == TranscriptExport.macSource && provenance.sessionId == id
    }

    /// Nothing at `url` (not even a dangling symlink), or a regular file this
    /// session already owns.
    public static func isFree(_ url: URL, for id: UUID) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if !exists {
            // fileExists follows symlinks; never write over a dangling one.
            return (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil
        }
        return !isDirectory.boolValue && isOwned(url, by: id)
    }

    /// The first candidate name for `base` in `dir` that this session may
    /// write, or nil when every candidate is taken by something else.
    public static func freeName(base: String, in dir: URL, for id: UUID) -> String? {
        candidates(base: base).first { isFree(dir.appendingPathComponent($0), for: id) }
    }
}
