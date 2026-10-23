#if DEBUG
import AVFoundation
import Foundation

/// DEBUG-only verification hook: `-seedSessionFromWAV <wavPath> <personName>`
/// turns an existing WAV into a recorded session for that person and runs
/// the real pipeline on it, so the `.ready` transition exercises the library
/// write without a microphone. (Task 9 folds this into DebugLaunchOptions.)
@MainActor
enum DebugSeed {
    private static var didRun = false

    static func runIfRequested(store: Store) {
        let args = ProcessInfo.processInfo.arguments
        guard !didRun, let i = args.firstIndex(of: "-seedSessionFromWAV"), i + 2 < args.count else { return }
        didRun = true
        // Seeding writes a session (and its library file): only ever into
        // scratch locations, never the real store or ~/Luxicon.
        guard args.contains("-libraryPath"), args.contains("-storePath") else {
            print("[seed] refused: -seedSessionFromWAV needs both -libraryPath and -storePath")
            return
        }
        let wavURL = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath)
        let name = args[i + 2]

        let person: Person
        if let existing = store.people.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            person = existing
        } else {
            person = Person(name: name)
            store.people.append(person)
            store.save()
        }

        var session = SessionRecord(personId: person.id, title: "1-on-1 with \(person.name)",
                                    date: Date(), duration: 0)
        let dest = store.audioURL(for: session)
        do {
            try FileManager.default.copyItem(at: wavURL, to: dest)
            let file = try AVAudioFile(forReading: dest)
            session.duration = Double(file.length) / file.fileFormat.sampleRate
        } catch {
            print("[seed] failed: \(error)")
            return
        }
        store.addSession(session)
        print("[seed] session \(session.id) for \(person.name), \(String(format: "%.1f", session.duration)) s")
        store.startProcessing(session)
    }
}
#endif
