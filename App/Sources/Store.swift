import Foundation
import Observation
import SitdownKit

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

    private struct Persisted: Codable {
        var people: [Person]
        var sessions: [SessionRecord]
        var myName: String
        var myVoiceEmbedding: [Float]?
    }

    static let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let storeURL = documentsURL.appendingPathComponent("store.json")
    static let audioDirURL = documentsURL.appendingPathComponent("audio", isDirectory: true)

    init() {
        try? FileManager.default.createDirectory(at: Self.audioDirURL, withIntermediateDirectories: true)
        load()
        // Recover sessions stuck mid-processing by an app kill.
        for i in sessions.indices where sessions[i].status == .processing {
            sessions[i].status = .recorded
        }
    }

    func load() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let persisted = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        people = persisted.people
        sessions = persisted.sessions
        myName = persisted.myName
        myVoiceEmbedding = persisted.myVoiceEmbedding
    }

    func save() {
        let persisted = Persisted(
            people: people, sessions: sessions,
            myName: myName, myVoiceEmbedding: myVoiceEmbedding
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
}
