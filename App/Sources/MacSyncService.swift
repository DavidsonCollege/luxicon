import Foundation
import LuxiconKit

/// Pushes finalized sessions to the paired Mac (`luxicon-mcp listen`) over the
/// local network. Fire-and-forget: the phone is a client, so a push simply
/// fails quietly when the Mac isn't reachable and retries next time.
extension Store {
    enum PushOutcome: Equatable {
        case notConfigured
        case success
        case failure(String)
    }

    /// Push one session's export envelope (transcript + summary).
    @discardableResult
    func pushToMac(_ session: SessionRecord) async -> PushOutcome {
        let token = syncToken.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty, let transcript = session.transcript else {
            return .notConfigured
        }
        do {
            let payload = try TranscriptExport.json(transcript, summary: session.summary)
            let person = person(id: session.personId)?.name ?? "session"
            let filename = "\(person) \(session.date.formatted(.iso8601.year().month().day())) \(session.id.uuidString.prefix(8)).json"
            let host = syncHost.trimmingCharacters(in: .whitespaces)
            try await LuxiconSync.push(
                filename: filename,
                payload: payload,
                token: token,
                host: host.isEmpty ? nil : host
            )
            return .success
        } catch {
            return .failure((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    /// Auto-push hook: called after a summary lands (or transcription finishes
    /// when auto-summarize is off).
    func autoPushIfEnabled(_ session: SessionRecord) {
        guard autoPushToMac, !syncToken.isEmpty else { return }
        Task { await pushToMac(session) }
    }

    /// Push every ready session for one person; returns (succeeded, total).
    func pushAll(for person: Person) async -> (succeeded: Int, total: Int) {
        let ready = sessions(for: person).filter { $0.status == .ready }
        var succeeded = 0
        for session in ready where await pushToMac(session) == .success {
            succeeded += 1
        }
        return (succeeded, ready.count)
    }
}
