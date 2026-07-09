import Foundation
import LuxiconKit

/// Three-way sync state for the UI. Meaningful only while Mac Sync is
/// enabled (`!syncToken.isEmpty`) and the session is `.ready`.
enum MacSyncState: Equatable {
    case synced(Date)
    case failed(String)
    case pending
}

extension SessionRecord {
    var macSyncState: MacSyncState {
        if let error = lastPushError { return .failed(error) }
        if let date = lastPushDate { return .synced(date) }
        return .pending
    }
}

/// Pushes finalized sessions to the paired Mac (`luxicon-mcp listen`) over the
/// local network. The phone is a client, so a push simply fails when the Mac
/// isn't reachable; each attempt's outcome is recorded on the session so the
/// UI can show it and retry.
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
        let outcome: PushOutcome
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
            outcome = .success
        } catch {
            outcome = .failure((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        recordPushOutcome(outcome, for: session.id)
        return outcome
    }

    /// Write the outcome onto the stored session (looked up by id — the
    /// parameter is a value copy, and the session may have been deleted
    /// mid-push).
    private func recordPushOutcome(_ outcome: PushOutcome, for id: UUID) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        switch outcome {
        case .success:
            sessions[i].lastPushDate = Date()
            sessions[i].lastPushError = nil
        case .failure(let message):
            sessions[i].lastPushError = message
        case .notConfigured:
            return
        }
        save()
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
