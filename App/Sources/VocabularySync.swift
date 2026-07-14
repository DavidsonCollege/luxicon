import Foundation
import LuxiconKit

/// Keeps the vocabulary synchronized with a user-provided URL. The remote
/// file is the source of truth: a successful sync replaces the glossary.
/// Runs on foreground activation (rate-limited) and on demand via Sync Now.
extension Store {
    private static let syncCooldown: TimeInterval = 60

    /// True while the glossary is kept synchronized from a URL. The synced
    /// file is the source of truth, so the vocabulary list UI switches to
    /// read-only — local edits would be silently replaced on the next sync.
    var vocabularySyncConfigured: Bool {
        !vocabularySourceURL.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Foreground/auto trigger; skips if unconfigured or synced recently.
    func syncVocabularyIfConfigured() {
        guard vocabularySyncConfigured else { return }
        if let last = vocabularyLastSyncAttempt,
           Date().timeIntervalSince(last) < Self.syncCooldown { return }
        Task { await syncVocabulary() }
    }

    /// One sync pass. Errors land in `vocabularySyncError` for the UI.
    func syncVocabulary() async {
        let urlString = vocabularySourceURL.trimmingCharacters(in: .whitespaces)
        guard !urlString.isEmpty else { return }
        guard let url = URL(string: urlString), url.scheme?.lowercased() == "https" else {
            vocabularySyncError = "Not a valid https URL. (Plain http would expose your auth headers.)"
            return
        }
        vocabularyLastSyncAttempt = Date()

        do {
            let (data, response) = try await RemoteSync.fetch(url: url, headers: vocabularyHeaders)
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                throw RemoteSync.SyncError.badStatus(http.statusCode, hint: RemoteSync.gitHubHint(for: http))
            }
            let entries = try VocabularyJSON.parse(data)
            vocabularyEntries = entries
            vocabularyLastSync = Date()
            // Sync succeeded — but tell the user about aliases the corrector
            // refuses to apply (common English words; see isProtectedAlias),
            // so the fix lands in the source file, not in silence.
            let ignored = VocabularyCorrector.ignoredAliases(in: entries)
            vocabularySyncError = ignored.isEmpty ? nil :
                "Synced, but ignoring unsafe soundsLike entries (common English words): "
                + ignored.map { "\"\($0.alias)\" → \($0.term)" }.joined(separator: ", ")
                + ". Remove them from the source file."
            save()
        } catch {
            vocabularySyncError = error.localizedDescription
        }
    }
}
