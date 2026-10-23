import Foundation
import Observation
import LuxiconKit

/// Where the shared session library lives: `~/Luxicon`, the folder the
/// phone's pushes land in (via the listener) and the MCP server reads.
/// DEBUG builds accept `-libraryPath <dir>` so test runs never touch the
/// real library.
enum LibraryLocation {
    static var url: URL { resolved }

    private static let resolved: URL = {
        var url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Luxicon", isDirectory: true)
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-libraryPath"), i + 1 < args.count {
            url = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath, isDirectory: true)
        }
        #endif
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
}

/// Read-only view of the shared library: sessions the phone pushed, Mac
/// sessions whose store record is gone, and a voice print sent from the
/// phone. The Mac's own sessions come from `Store`, never from here.
@Observable @MainActor
final class LibraryIndex {
    var phoneSessions: [TranscriptLibrary.Session] = []
    var orphanMacSessions: [TranscriptLibrary.Session] = []
    var voicePrint: VoicePrintFile?

    @ObservationIgnored let directory: URL
    /// Bumped per reload so a slow parse can't overwrite a newer result.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var watcher: DirectoryWatcher?
    #if DEBUG
    @ObservationIgnored private(set) var reloadCount = 0
    #endif

    init(directory: URL = LibraryLocation.url) {
        self.directory = directory
    }

    /// Rescan the library. Parsing runs off the main actor: the folder holds
    /// every session ever pushed, and each file is a full transcript.
    func reload(ownedIds: Set<UUID>) async {
        generation += 1
        let thisReload = generation
        let dir = directory
        let (all, voice) = await Task.detached(priority: .utility) {
            let sessions = TranscriptLibrary.load(from: dir).sessions
            let printData = try? Data(contentsOf: dir.appendingPathComponent(VoicePrintFile.filename))
            return (sessions, printData.flatMap(VoicePrintFile.decode))
        }.value
        guard thisReload == generation else { return }
        phoneSessions = LibraryMerge.phoneSessions(all, ownedIds: ownedIds)
        orphanMacSessions = LibraryMerge.orphanMacSessions(all, ownedIds: ownedIds)
        if voicePrint != voice { voicePrint = voice }
        #if DEBUG
        reloadCount += 1
        debugLog("reload #\(reloadCount): phone=\(phoneSessions.count) orphanMac=\(orphanMacSessions.count) voicePrint=\(voicePrint != nil)")
        #endif
    }

    /// Reload whenever the folder changes (debounced). `ownedIds` is read at
    /// reload time so it reflects the store as it is then. Idempotent.
    func startWatching(ownedIds: @escaping @MainActor () -> Set<UUID>) {
        guard watcher == nil else { return }
        let watcher = DirectoryWatcher(url: directory) { [weak self] in
            guard let self else { return }
            #if DEBUG
            self.debugLog("watcher fired")
            #endif
            Task { await self.reload(ownedIds: ownedIds()) }
        }
        watcher.start()
        self.watcher = watcher
    }

    func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    /// People with phone sessions in the library who aren't in the Mac's list.
    func libraryOnlyPeople(known: [Person]) -> [String] {
        LibraryMerge.libraryOnlyNames(phoneSessions, knownNames: known.map(\.name))
    }

    /// Phone sessions for a person, matched by name (case-insensitive),
    /// oldest first.
    func phoneSessions(forPersonNamed name: String) -> [TranscriptLibrary.Session] {
        phoneSessions
            .filter { $0.person.localizedCaseInsensitiveCompare(name) == .orderedSame }
            .sorted { $0.transcript.date < $1.transcript.date }
    }

    #if DEBUG
    private func debugLog(_ message: String) {
        let t = String(format: "%.3f", Date().timeIntervalSince1970)
        Swift.print("[library \(t)] \(message)")
        fflush(stdout)
    }
    #endif
}
