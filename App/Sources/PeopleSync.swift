import Foundation
import LuxiconKit

/// Keeps the people roster synchronized with a user-provided URL. Unlike
/// vocabulary sync, the remote file is NOT the source of truth: each sync
/// merges via `importPeople` (adds/updates by name, applies the "me" entry
/// to the user's own context) and never removes anyone — a Person owns
/// sessions and photos that sync must not destroy. Runs on foreground
/// activation (rate-limited) and on demand via Sync Now.
extension Store {
    private static let peopleSyncCooldown: TimeInterval = 60

    /// True while the roster is kept synchronized from a URL. The synced
    /// file owns context (each person's and the user's own), so the context
    /// UI switches to read-only.
    var peopleSyncConfigured: Bool {
        !peopleSourceURL.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Foreground/auto trigger; skips if unconfigured or synced recently.
    func syncPeopleIfConfigured() {
        guard peopleSyncConfigured else { return }
        if let last = peopleLastSyncAttempt,
           Date().timeIntervalSince(last) < Self.peopleSyncCooldown { return }
        Task { await syncPeople() }
    }

    /// One sync pass. Errors land in `peopleSyncError` for the UI.
    func syncPeople() async {
        let urlString = peopleSourceURL.trimmingCharacters(in: .whitespaces)
        guard !urlString.isEmpty else { return }
        guard let url = URL(string: urlString), url.scheme?.lowercased() == "https" else {
            peopleSyncError = "Not a valid https URL. (Plain http would expose your auth headers.)"
            return
        }
        peopleLastSyncAttempt = Date()

        do {
            let (data, response) = try await RemoteSync.fetch(url: url, headers: peopleHeaders)
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                throw RemoteSync.SyncError.badStatus(http.statusCode, hint: RemoteSync.gitHubHint(for: http))
            }
            let file = try PeopleJSON.parse(data)
            _ = importPeople(file)
            peopleLastSync = Date()
            peopleSyncError = nil
            save()
        } catch {
            peopleSyncError = error.localizedDescription
        }
    }
}
