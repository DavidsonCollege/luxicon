import Foundation
import Observation
import UIKit
import LuxiconKit

/// A direct report you hold 1-on-1s with.
struct Person: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// Profile picture file in `Store.photosDirURL`, if one has been set.
    var photoFileName: String?
    /// Background for the summarizer: role, projects, current threads.
    var context: String?
}

/// Which engine generates AI summaries. Apple Intelligence only since
/// 2026-07 — the in-process MLX era (Qwen3.5, Gemma 4) ended with the
/// per-process memory ceiling. The enum survives because store.json
/// persists it, and it is the seam a future engine would plug back into.
enum SummaryEngine: String, Codable {
    case appleIntelligence

    /// Tolerant decode: a retired engine persisted by an older build
    /// ("gemma") maps to Apple Intelligence instead of failing the entire
    /// store.json decode and taking the user's library with it.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SummaryEngine(rawValue: raw) ?? .appleIntelligence
    }
}

/// One recorded 1-on-1.
struct SessionRecord: Codable, Identifiable, Equatable {
    enum Status: String, Codable {
        case recorded      // audio saved, not yet processed
        case processing
        case ready
        case failed
    }

    var id = UUID()
    var personId: UUID
    var title: String
    var date: Date
    var duration: Double
    var status: Status = .recorded
    var transcript: MeetingTranscript?
    /// On-device LLM summary; separate from the transcript by design.
    var summary: SessionSummary?
    /// Terse one-line label (topics only) shown exclusively in the
    /// conversations list — generated alongside the summary but stored apart
    /// from it. Optional so pre-existing store.json decodes unchanged.
    var listLabel: String?
    var errorMessage: String?
    /// Mac Sync: when this session last pushed successfully, and the error
    /// message from the last failed attempt (nil after a success). Optionals
    /// so pre-existing store.json decodes unchanged.
    var lastPushDate: Date?
    var lastPushError: String?

    var audioFileName: String { "\(id.uuidString).wav" }
}

/// App state persisted as JSON + WAV files under Documents.
/// Everything stays on-device.
@Observable @MainActor
final class Store {
    var people: [Person] = []
    var sessions: [SessionRecord] = []
    /// Display name the user goes by (used to label their own turns).
    var myName: String = "Me"
    /// The user's own profile picture file in `photosDirURL`, if set.
    var myPhotoFileName: String?
    /// Background about the user fed to the summarizer, like `Person.context`.
    var myContext: String = ""
    /// Speaker embedding of the user's enrolled voice, if enrolled.
    var myVoiceEmbedding: [Float]?
    /// User-defined terms (jargon, project names) to ground transcription in.
    var vocabularyEntries: [VocabularyEntry] = []
    /// Explicit engine choice from settings; nil means automatic
    /// (Apple's system transcriber on iOS 26+, else Parakeet).
    var asrEngineChoice: ASREngine?
    var asrEngine: ASREngine { asrEngineChoice ?? .resolvedDefault() }
    /// Master switch for the AI features (summaries, list labels, personal
    /// context). Off by default: enabling attaches to the Apple Intelligence
    /// system model (OS-managed, no download). When off, the summary and
    /// context UI is hidden entirely.
    var aiSummariesEnabled = false
    /// Engine behind the summaries; nil until the user enables the feature.
    /// Always .appleIntelligence today (retired engines decode to it), kept
    /// as persisted state so a future engine can slot back in.
    var summaryEngine: SummaryEngine?
    /// Generate a summary automatically after each transcription (only
    /// meaningful while `aiSummariesEnabled`).
    var autoSummarize = true
    /// Transient model-download progress for the enable flow; not persisted.
    var summaryModelDownloadStage: String?
    /// Transient error from the last enable attempt; not persisted.
    var summaryModelError: String?
    /// Mac sync: pairing token, optional manual host (for squashed-mDNS
    /// networks), and whether to push automatically after each session.
    var syncToken: String = ""
    var syncHost: String = ""
    var autoPushToMac = false
    /// Remote vocabulary file kept in sync; when set, it is the source of
    /// truth and each sync replaces `vocabularyEntries`.
    var vocabularySourceURL: String = ""
    /// Request headers for the sync fetch (e.g. Authorization). Stored in the
    /// app's on-device container like everything else.
    var vocabularyHeaders: [HTTPHeader] = []
    var vocabularyLastSync: Date?
    /// Transient sync status for the UI; not persisted.
    var vocabularySyncError: String?
    @ObservationIgnored var vocabularyLastSyncAttempt: Date?
    /// Remote people roster kept in sync; unlike vocabulary, each sync
    /// merges (adds/updates by name) and never removes anyone.
    var peopleSourceURL: String = ""
    var peopleHeaders: [HTTPHeader] = []
    var peopleLastSync: Date?
    /// Transient sync status for the UI; not persisted.
    var peopleSyncError: String?
    @ObservationIgnored var peopleLastSyncAttempt: Date?
    /// Rate limit for the foreground failed-push retry sweep.
    @ObservationIgnored var lastPushRetrySweep: Date?
    /// Sessions with a push on the wire; auto-push, manual retry, and the
    /// foreground sweep can otherwise target one session concurrently.
    @ObservationIgnored var pushesInFlight: Set<UUID> = []
    /// Set when the persisted library could not be read at launch (the file
    /// is quarantined, never overwritten). Shown once by the root view.
    var startupWarning: String?
    /// Set when store.json exists but reading it failed — how a launch looks
    /// while the device is locked (prewarming, background audio relaunch):
    /// Documents is `.completeUnlessOpen`, so the bytes are undecryptable
    /// until unlock even though the file is listable. While pending, save()
    /// is a no-op so the blank in-memory state can never overwrite the
    /// on-disk library; the load retries on unlock and on foreground.
    @ObservationIgnored private(set) var loadPending = false
    /// Retry-on-unlock observer; lives as long as the store (see LiveCaptioner
    /// for the storage pattern).
    @ObservationIgnored nonisolated(unsafe) private var protectedDataObserver: NSObjectProtocol?
    /// Set when persisting the library fails (e.g. storage full).
    var saveError: String?

    struct HTTPHeader: Codable, Equatable, Identifiable {
        var id = UUID()
        var name: String = ""
        var value: String = ""
    }

    private struct Persisted: Codable {
        var people: [Person]
        var sessions: [SessionRecord]
        var myName: String
        var myPhotoFileName: String?
        var myContext: String?
        var myVoiceEmbedding: [Float]?
        /// Pre-0.1.0(4) plain-string vocabulary; migrated to `vocabularyEntries`.
        var customVocabulary: [String]?
        var vocabularyEntries: [VocabularyEntry]?
        /// Legacy engine field: ignored on read, never written. Post-Qwen3
        /// retirement it can only decode to .parakeet, and a default was
        /// never distinguishable from a choice under this key anyway.
        var asrEngine: ASREngine?
        var asrEngineChoice: ASREngine?
        var vocabularySourceURL: String?
        var vocabularyHeaders: [HTTPHeader]?
        var vocabularyLastSync: Date?
        var aiSummariesEnabled: Bool?
        var summaryEngine: SummaryEngine?
        var autoSummarize: Bool?
        var syncToken: String?
        var syncHost: String?
        var autoPushToMac: Bool?
        var peopleSourceURL: String?
        var peopleLastSync: Date?
    }

    static let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let storeURL = documentsURL.appendingPathComponent("store.json")
    static let audioDirURL = documentsURL.appendingPathComponent("audio", isDirectory: true)
    static let photosDirURL = documentsURL.appendingPathComponent("photos", isDirectory: true)

    private static let keychainSyncToken = "syncToken"
    private static let keychainVocabHeaders = "vocabularyHeaders"
    private static let keychainPeopleHeaders = "peopleHeaders"

    /// Read the people list without constructing a Store (no recovery side
    /// effects) — used by App Intents entity queries.
    static func peekPeople() -> [Person] {
        guard let data = try? Data(contentsOf: storeURL),
              let persisted = try? JSONDecoder().decode(Persisted.self, from: data) else { return [] }
        return persisted.people
    }

    init() {
        try? FileManager.default.createDirectory(at: Self.audioDirURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: Self.photosDirURL, withIntermediateDirectories: true)
        // Data protection: new files inherit the directory's class, so the
        // library is unreadable while the device is locked. The live recording
        // stays writable because its file is already open (`completeUnlessOpen`).
        for url in [Self.documentsURL, Self.audioDirURL, Self.photosDirURL] {
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUnlessOpen],
                ofItemAtPath: url.path)
        }
        load()
        if !loadPending { finishStartup() }
        // Locked-launch recovery: the moment the content becomes readable,
        // load for real. Registered unconditionally — the handler no-ops
        // unless a load is actually pending.
        protectedDataObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryPendingLoad() }
        }
    }

    deinit {
        if let protectedDataObserver {
            NotificationCenter.default.removeObserver(protectedDataObserver)
        }
    }

    /// One-time recovery passes that must only run against real library
    /// state — after a successful (possibly deferred) load, never before.
    private func finishStartup() {
        // Builds 1-9 cached the old Qwen summarizer (~400 MB); reclaim it.
        removeLegacySummaryModel()
        // Recover sessions stuck mid-processing by an app kill.
        for i in sessions.indices where sessions[i].status == .processing {
            sessions[i].status = .recorded
        }
        recoverInterruptedRecordings()
    }

    /// Re-run a load that was deferred because store.json was unreadable
    /// (device locked). Called on unlock and on foreground; no-op otherwise.
    func retryPendingLoad() {
        guard loadPending else { return }
        load()
        guard !loadPending else { return }
        finishStartup()
    }

    func load() {
        // Secrets live in the Keychain; store.json copies (pre-build-6) migrate below.
        syncToken = KeychainStore.string(for: Self.keychainSyncToken) ?? ""
        vocabularyHeaders = KeychainStore.data(for: Self.keychainVocabHeaders)
            .flatMap { try? JSONDecoder().decode([HTTPHeader].self, from: $0) } ?? []
        peopleHeaders = KeychainStore.data(for: Self.keychainPeopleHeaders)
            .flatMap { try? JSONDecoder().decode([HTTPHeader].self, from: $0) } ?? []

        loadPending = false
        guard FileManager.default.fileExists(atPath: Self.storeURL.path) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: Self.storeURL)
        } catch {
            // Unreadable is not corrupt. This is the locked-device launch
            // (NSFileReadNoPermission on a `.completeUnlessOpen` file):
            // the library on disk is healthy, so leave it exactly where it
            // is and try again when the content becomes readable.
            loadPending = true
            return
        }
        let persisted: Persisted
        do {
            persisted = try JSONDecoder().decode(Persisted.self, from: data)
        } catch {
            // Never overwrite what we can't read: set it aside so the next
            // save() can't destroy the library, and tell the user.
            let backupName = "store.corrupt-\(Int(Date().timeIntervalSince1970)).json"
            try? FileManager.default.moveItem(
                at: Self.storeURL,
                to: Self.documentsURL.appendingPathComponent(backupName))
            startupWarning = "The session library could not be read, so it was set aside as \(backupName) and Luxicon started fresh. Audio files are untouched. Please report this."
            return
        }
        people = persisted.people
        sessions = persisted.sessions
        myName = persisted.myName
        myPhotoFileName = persisted.myPhotoFileName
        myContext = persisted.myContext ?? ""
        myVoiceEmbedding = persisted.myVoiceEmbedding
        vocabularyEntries = persisted.vocabularyEntries
            ?? (persisted.customVocabulary ?? []).map { VocabularyEntry(term: $0) }
        asrEngineChoice = persisted.asrEngineChoice
        vocabularySourceURL = persisted.vocabularySourceURL ?? ""
        vocabularyLastSync = persisted.vocabularyLastSync
        // Existing users (builds 1-9) had always-on summarization via the old
        // 0.8B model; the feature is now an explicit opt-in with a larger
        // model, so it starts off for everyone. Old summaries stay readable.
        aiSummariesEnabled = persisted.aiSummariesEnabled ?? false
        // Apple Intelligence is the only engine; a stored retired engine
        // ("gemma") already decoded to it, and enabled-without-choice
        // (pre-engine-picker builds) resolves to it here. The next summary
        // surfaces an availability error if this device can't run it.
        summaryEngine = persisted.summaryEngine ?? (aiSummariesEnabled ? .appleIntelligence : nil)
        autoSummarize = persisted.autoSummarize ?? true
        syncHost = persisted.syncHost ?? ""
        autoPushToMac = persisted.autoPushToMac ?? false
        peopleSourceURL = persisted.peopleSourceURL ?? ""
        peopleLastSync = persisted.peopleLastSync

        // One-way migration: secrets that older builds kept in store.json.
        if let legacyToken = persisted.syncToken, !legacyToken.isEmpty {
            syncToken = legacyToken
            KeychainStore.set(legacyToken, for: Self.keychainSyncToken)
        }
        if let legacyHeaders = persisted.vocabularyHeaders, !legacyHeaders.isEmpty {
            vocabularyHeaders = legacyHeaders
            KeychainStore.set(try? JSONEncoder().encode(legacyHeaders), for: Self.keychainVocabHeaders)
        }
    }

    func save() {
        // A pending load means the on-disk library exists but has never been
        // read this launch; writing now would replace it with blank state.
        guard !loadPending else { return }
        KeychainStore.set(syncToken, for: Self.keychainSyncToken)
        KeychainStore.set(
            vocabularyHeaders.isEmpty ? nil : try? JSONEncoder().encode(vocabularyHeaders),
            for: Self.keychainVocabHeaders)
        KeychainStore.set(
            peopleHeaders.isEmpty ? nil : try? JSONEncoder().encode(peopleHeaders),
            for: Self.keychainPeopleHeaders)

        let persisted = Persisted(
            people: people, sessions: sessions,
            myName: myName, myPhotoFileName: myPhotoFileName,
            myContext: myContext.isEmpty ? nil : myContext,
            myVoiceEmbedding: myVoiceEmbedding,
            customVocabulary: nil, vocabularyEntries: vocabularyEntries,
            asrEngine: nil,                    // legacy key: read-only (see Persisted)
            asrEngineChoice: asrEngineChoice,
            vocabularySourceURL: vocabularySourceURL.isEmpty ? nil : vocabularySourceURL,
            vocabularyHeaders: nil,  // Keychain-only since build 6
            vocabularyLastSync: vocabularyLastSync,
            aiSummariesEnabled: aiSummariesEnabled,
            summaryEngine: summaryEngine,
            autoSummarize: autoSummarize,
            syncToken: nil,          // Keychain-only since build 6
            syncHost: syncHost.isEmpty ? nil : syncHost,
            autoPushToMac: autoPushToMac,
            peopleSourceURL: peopleSourceURL.isEmpty ? nil : peopleSourceURL,
            peopleLastSync: peopleLastSync
        )
        do {
            let data = try JSONEncoder().encode(persisted)
            try data.write(to: Self.storeURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            saveError = nil
        } catch {
            saveError = "Could not save the session library: \(error.localizedDescription). Free up storage and try again."
        }
    }

    // MARK: - Convenience

    func sessions(for person: Person) -> [SessionRecord] {
        sessions.filter { $0.personId == person.id }.sorted { $0.date > $1.date }
    }

    func person(id: UUID) -> Person? { people.first { $0.id == id } }

    func audioURL(for session: SessionRecord) -> URL {
        Self.audioDirURL.appendingPathComponent(session.audioFileName)
    }

    func update(_ session: SessionRecord) {
        if let i = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[i] = session
            save()
        }
    }

    func addSession(_ session: SessionRecord) {
        sessions.append(session)
        save()
    }

    func deleteSession(_ session: SessionRecord) {
        sessions.removeAll { $0.id == session.id }
        try? FileManager.default.removeItem(at: audioURL(for: session))
        save()
    }

    func deletePerson(_ person: Person) {
        for s in sessions(for: person) { deleteSession(s) }
        if let current = self.person(id: person.id) {
            removePhotoFile(current.photoFileName)
        }
        people.removeAll { $0.id == person.id }
        save()
    }

    // MARK: - Profile photos (aesthetic only)

    static func photoURL(fileName: String) -> URL {
        photosDirURL.appendingPathComponent(fileName)
    }

    /// Set or clear (`nil`) a person's profile picture. `data` should already
    /// be encoded image data (see AvatarView's downscaling picker).
    func setPhoto(_ data: Data?, for personId: UUID) {
        guard let i = people.firstIndex(where: { $0.id == personId }) else { return }
        people[i].photoFileName = replacePhotoFile(old: people[i].photoFileName, with: data)
        save()
    }

    /// Set or clear (`nil`) the user's own profile picture.
    func setMyPhoto(_ data: Data?) {
        myPhotoFileName = replacePhotoFile(old: myPhotoFileName, with: data)
        save()
    }

    /// Each photo gets a fresh filename so SwiftUI image caches can never
    /// show a stale picture. Returns the new filename, or nil when clearing.
    private func replacePhotoFile(old: String?, with data: Data?) -> String? {
        removePhotoFile(old)
        guard let data else { return nil }
        let fileName = "\(UUID().uuidString).jpg"
        do {
            try data.write(to: Self.photoURL(fileName: fileName), options: .atomic)
            return fileName
        } catch {
            return nil
        }
    }

    private func removePhotoFile(_ fileName: String?) {
        guard let fileName else { return }
        try? FileManager.default.removeItem(at: Self.photoURL(fileName: fileName))
    }

    var enrollments: [VoiceEnrollment] {
        guard let emb = myVoiceEmbedding else { return [] }
        return [VoiceEnrollment(name: myName, embedding: emb)]
    }

    /// Terms likely to occur in any session: everyone's names + custom glossary.
    var vocabulary: [VocabularyEntry] {
        var entries = people.map { VocabularyEntry(term: $0.name, category: "name") }
        if myName != "Me" {
            entries.append(VocabularyEntry(term: myName, category: "name"))
        }
        return entries + vocabularyEntries
    }

    /// Merge imported entries into the glossary; imported rows win on term
    /// collisions (case-insensitive). Returns the number of entries applied.
    func importVocabulary(_ imported: [VocabularyEntry]) -> Int {
        for entry in imported {
            if let i = vocabularyEntries.firstIndex(where: {
                $0.term.caseInsensitiveCompare(entry.term) == .orderedSame
            }) {
                vocabularyEntries[i] = entry
            } else {
                vocabularyEntries.append(entry)
            }
        }
        save()
        return imported.count
    }

    /// Merge an imported roster by case-insensitive name: new people are
    /// appended, matches get their context updated when the import provides
    /// one. Never removes anyone — photos and sessions are untouched.
    /// The file's "me" entry updates the user's own about-me context.
    func importPeople(_ file: PeopleFile) -> (added: Int, updated: Int) {
        var added = 0, updated = 0
        if let context = file.myContext, myContext != context {
            myContext = context
            updated += 1
        }
        for record in file.people {
            // "You" are not a roster row: an org-chart-fed file usually
            // includes the manager — route that context to My Voice instead
            // of forking a duplicate Person under your own name.
            if record.name.caseInsensitiveCompare(myName) == .orderedSame {
                if let context = record.context, myContext != context {
                    myContext = context
                    updated += 1
                }
                continue
            }
            let matches = people.indices.filter {
                people[$0].name.caseInsensitiveCompare(record.name) == .orderedSame
            }
            if matches.isEmpty {
                people.append(Person(name: record.name, context: record.context))
                added += 1
            } else if let context = record.context {
                // Duplicate local names are possible; update every match so
                // context can't silently land on only the wrong row.
                var changed = false
                for i in matches where people[i].context != context {
                    people[i].context = context
                    changed = true
                }
                if changed { updated += 1 }
            }
        }
        save()
        return (added, updated)
    }

    /// Roster in the Kit exchange shape, for export and agent prompts.
    var peopleForExport: [PersonImport] {
        people.map { PersonImport(name: $0.name, context: $0.context) }
    }

    /// The user themself in the exchange shape — the file's "me" entry.
    var meForExport: PersonImport {
        PersonImport(name: myName, context: myContext.isEmpty ? nil : myContext)
    }

    // MARK: - In-progress recording (crash recovery)

    /// Metadata written when a recording starts, so a crash mid-recording can
    /// be reconstructed into a session on next launch.
    struct RecordingSidecar: Codable {
        var personId: UUID
        var title: String
        var date: Date
    }

    func inProgressAudioURL(id: UUID) -> URL {
        Self.audioDirURL.appendingPathComponent("\(id.uuidString).recording.wav")
    }

    private func sidecarURL(id: UUID) -> URL {
        Self.audioDirURL.appendingPathComponent("\(id.uuidString).recording.json")
    }

    func beginRecording(id: UUID, person: Person) throws -> URL {
        let sidecar = RecordingSidecar(
            personId: person.id,
            title: "1-on-1 with \(person.name)",
            date: Date()
        )
        try JSONEncoder().encode(sidecar).write(to: sidecarURL(id: id), options: .atomic)
        return inProgressAudioURL(id: id)
    }

    /// Clean stop: promote the in-progress file to a real session.
    func finishRecording(id: UUID, duration: Double) throws -> SessionRecord {
        let sidecar = try JSONDecoder().decode(
            RecordingSidecar.self, from: Data(contentsOf: sidecarURL(id: id)))
        var session = SessionRecord(
            personId: sidecar.personId,
            title: sidecar.title,
            date: sidecar.date,
            duration: duration
        )
        session.id = id
        try FileManager.default.moveItem(
            at: inProgressAudioURL(id: id), to: audioURL(for: session))
        try? FileManager.default.removeItem(at: sidecarURL(id: id))
        addSession(session)
        return session
    }

    func discardRecording(id: UUID) {
        try? FileManager.default.removeItem(at: inProgressAudioURL(id: id))
        try? FileManager.default.removeItem(at: sidecarURL(id: id))
    }

    /// Turn recordings orphaned by a crash into normal sessions.
    private func recoverInterruptedRecordings() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.audioDirURL, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.lastPathComponent.hasSuffix(".recording.wav") {
            let base = url.lastPathComponent.replacingOccurrences(of: ".recording.wav", with: "")
            guard let id = UUID(uuidString: base) else { continue }
            do {
                // The writer died before finalize; rebuild the header from file size.
                let duration = try WAVFile.repairHeader(
                    url: url, sampleRate: MeetingPipeline.sampleRate)
                guard duration > 1 else {
                    discardRecording(id: id)
                    continue
                }
                _ = try finishRecording(id: id, duration: duration)
            } catch {
                // Leave the files in place; a future launch may succeed.
            }
        }
    }
}
