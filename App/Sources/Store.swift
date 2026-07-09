import Foundation
import Observation
import LuxiconKit

/// A direct report you hold 1-on-1s with.
struct Person: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
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
    var errorMessage: String?

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
    /// Speaker embedding of the user's enrolled voice, if enrolled.
    var myVoiceEmbedding: [Float]?
    /// User-defined terms (jargon, project names) to ground transcription in.
    var vocabularyEntries: [VocabularyEntry] = []
    /// Which ASR engine transcribes turns.
    var asrEngine: ASREngine = .parakeet
    /// Generate a summary automatically after each transcription.
    var autoSummarize = true
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

    struct HTTPHeader: Codable, Equatable, Identifiable {
        var id = UUID()
        var name: String = ""
        var value: String = ""
    }

    private struct Persisted: Codable {
        var people: [Person]
        var sessions: [SessionRecord]
        var myName: String
        var myVoiceEmbedding: [Float]?
        /// Pre-0.1.0(4) plain-string vocabulary; migrated to `vocabularyEntries`.
        var customVocabulary: [String]?
        var vocabularyEntries: [VocabularyEntry]?
        var asrEngine: ASREngine?
        var vocabularySourceURL: String?
        var vocabularyHeaders: [HTTPHeader]?
        var vocabularyLastSync: Date?
        var autoSummarize: Bool?
        var syncToken: String?
        var syncHost: String?
        var autoPushToMac: Bool?
    }

    static let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let storeURL = documentsURL.appendingPathComponent("store.json")
    static let audioDirURL = documentsURL.appendingPathComponent("audio", isDirectory: true)

    /// Read the people list without constructing a Store (no recovery side
    /// effects) — used by App Intents entity queries.
    static func peekPeople() -> [Person] {
        guard let data = try? Data(contentsOf: storeURL),
              let persisted = try? JSONDecoder().decode(Persisted.self, from: data) else { return [] }
        return persisted.people
    }

    init() {
        try? FileManager.default.createDirectory(at: Self.audioDirURL, withIntermediateDirectories: true)
        load()
        // Recover sessions stuck mid-processing by an app kill.
        for i in sessions.indices where sessions[i].status == .processing {
            sessions[i].status = .recorded
        }
        recoverInterruptedRecordings()
    }

    func load() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let persisted = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        people = persisted.people
        sessions = persisted.sessions
        myName = persisted.myName
        myVoiceEmbedding = persisted.myVoiceEmbedding
        vocabularyEntries = persisted.vocabularyEntries
            ?? (persisted.customVocabulary ?? []).map { VocabularyEntry(term: $0) }
        asrEngine = persisted.asrEngine ?? .parakeet
        vocabularySourceURL = persisted.vocabularySourceURL ?? ""
        vocabularyHeaders = persisted.vocabularyHeaders ?? []
        vocabularyLastSync = persisted.vocabularyLastSync
        autoSummarize = persisted.autoSummarize ?? true
        syncToken = persisted.syncToken ?? ""
        syncHost = persisted.syncHost ?? ""
        autoPushToMac = persisted.autoPushToMac ?? false
    }

    func save() {
        let persisted = Persisted(
            people: people, sessions: sessions,
            myName: myName, myVoiceEmbedding: myVoiceEmbedding,
            customVocabulary: nil, vocabularyEntries: vocabularyEntries,
            asrEngine: asrEngine,
            vocabularySourceURL: vocabularySourceURL.isEmpty ? nil : vocabularySourceURL,
            vocabularyHeaders: vocabularyHeaders.isEmpty ? nil : vocabularyHeaders,
            vocabularyLastSync: vocabularyLastSync,
            autoSummarize: autoSummarize,
            syncToken: syncToken.isEmpty ? nil : syncToken,
            syncHost: syncHost.isEmpty ? nil : syncHost,
            autoPushToMac: autoPushToMac
        )
        if let data = try? JSONEncoder().encode(persisted) {
            try? data.write(to: Self.storeURL, options: .atomic)
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
        people.removeAll { $0.id == person.id }
        save()
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
        try JSONEncoder().encode(sidecar).write(to: sidecarURL(id: id))
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
