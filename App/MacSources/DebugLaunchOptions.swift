#if DEBUG
import AppKit
import AVFoundation
import os
import SwiftUI
import LuxiconKit

/// DEBUG-only launch arguments, parsed in one place so flag order never
/// matters: each known flag consumes exactly its own values, and a
/// valueless flag never swallows the next one.
///
/// Fixture data (all refuse to run without `-storePath`, and the seed also
/// needs `-libraryPath`, so they only ever write scratch locations):
/// - `-libraryPath <dir>`, `-storePath <dir>`: scratch library / store.
/// - `-importPeople <path>`: the People screen's importer (`PeopleJSON`).
/// - `-importVocabulary <path>`: the Vocabulary screen's importer.
/// - `-myName <name>`: the user's name (onboarding step 1).
/// - `-importPhotos <dir>`: each `<Name>.jpg` becomes that person's photo
///   (case-insensitive name match), or the user's own when it matches
///   `myName`, through the avatar pickers' downscale-and-save path.
/// - `-seedSessionFromWAV <wav> <name>`: a recorded session for that person
///   (created if needed), run through the real pipeline.
/// - `-deletePersonNamed <name>`: once the library has loaded, delete that
///   person through `Store.deletePerson`, the sidebar's Delete… action.
/// - `-asrEngine <raw>`: the Settings → Transcription choice (`ASREngine`
///   raw value: `parakeet`, `appleSpeech`, `cohere`; `automatic` clears it).
///
/// Failure injection:
/// - `-simulateModelDownloadFailure`: the next Cohere model load throws
///   what URLSession throws offline (`URLError.notConnectedToInternet`);
///   later loads in the same run proceed, so Retry recovers.
/// - `-retryFailedSessions`: once the library has loaded, press Retry on
///   every failed session (`Store.startProcessing`, the button's action).
///   Scratch locations only.
///
/// Screens (for `scripts/mac-screenshots.sh`):
/// - `-route sidebar:all | sidebar:vocabulary | person:<uuid> | library:<name>
///   | session:<uuid> | librarySession:<libraryKey> | record:<personUUID>
///   | settings | onboarding`
/// - `-windowSize <w>x<h>`: the route's window content size (the recording
///   window is fixed-size, so `record:` sizes the main window behind it).
/// - `-appearance light|dark`: `NSApp.appearance`.
/// - `-printWindowID`: once laid out, print `WINDOW_ID <n>` (the route's
///   window; for `onboarding`, the main window under the sheet) to stdout.
///
/// Updater (Sparkle is off in DEBUG unless `-enableUpdater`; run it only in
/// a build whose bundle id is `edu.davidson.luxicon.mac.updatetest`):
/// - `-enableUpdater`: start Sparkle.
/// - `-updateFeedURL <url>`: a scratch appcast instead of `SUFeedURL`.
/// - `-checkInBackgroundAt <seconds>`: that long after launch, run a
///   scheduled-path (background) check, as Sparkle's own schedule would.
/// An `.updatetest` build quits at launch without both `-storePath` and
/// `-libraryPath` (`refuseUpdateTestWithoutScratchPaths`), so Sparkle's
/// argument-less relaunch never opens the real store or library.
///
/// Recording hooks (`-recordWith`, `-noMicrophone`, `-simulate…`,
/// `-answerPromptWith`, and the picker/mute hooks `-simulateMuteAt`,
/// `-selectInputNamed`, …) are documented on `DebugRecording`; `-openSettings`
/// and `-autoUseVoicePrint` drive Settings and the voice-print banner.
enum DebugLaunchOptions {
    /// Every flag that takes values, with its value count. Anything else
    /// starting with "-" is a valueless flag.
    private static let valueCounts: [String: Int] = [
        "-libraryPath": 1, "-storePath": 1,
        "-importPeople": 1, "-importVocabulary": 1, "-importPhotos": 1, "-myName": 1,
        "-seedSessionFromWAV": 2, "-deletePersonNamed": 1, "-asrEngine": 1,
        "-route": 1, "-windowSize": 1, "-appearance": 1,
        "-recordWith": 1, "-simulateMicrophone": 1, "-simulateCaptions": 1, "-answerPromptWith": 1,
        "-simulateSleepAfter": 1, "-simulateCloseAfter": 1, "-simulateStopAfter": 1,
        "-simulateQuitAfter": 1, "-simulatePermissionDelay": 1,
        "-simulateMuteAt": 1, "-simulateUnmuteAt": 1, "-simulateMuteSource": 1, "-simulateStartMuted": 1,
        "-simulateManualOffAt": 1, "-simulateManualResumeAt": 1, "-selectInputNamed": 2,
        "-simulateInputGoneAt": 1, "-simulateUnmuteButtonAt": 1,
        "-updateFeedURL": 1, "-checkInBackgroundAt": 1,
    ]

    /// Flag → its values (empty for a valueless flag).
    static let parsed: [String: [String]] = parse(ProcessInfo.processInfo.arguments)

    static func parse(_ arguments: [String]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        var i = 1
        while i < arguments.count {
            let arg = arguments[i]
            if let count = valueCounts[arg] {
                let values = Array(arguments.dropFirst(i + 1).prefix(count))
                if values.count == count { result[arg] = values }
                i += 1 + count
            } else {
                // Valueless flag, or a stray value (e.g. AppKit's own
                // `-NSFoo YES` pairs): a flag is recorded, a value skipped.
                if arg.hasPrefix("-") { result[arg] = [] }
                i += 1
            }
        }
        return result
    }

    static func has(_ flag: String) -> Bool { parsed[flag] != nil }
    static func value(_ flag: String) -> String? { parsed[flag]?.first }
    static func values(_ flag: String) -> [String]? { parsed[flag] }
    static func path(_ flag: String) -> URL? {
        value(flag).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("[debug] \(message)\n".utf8))
    }

    /// An `.updatetest` build (the bundle id the updater's end-to-end checks
    /// use) quits at once unless both `-storePath` and `-libraryPath` are
    /// given. Sparkle relaunches an updated app without launch arguments,
    /// and without them a Debug build opens the real store and ~/Luxicon.
    /// Runs before the Store exists, so nothing real is read or written.
    static func refuseUpdateTestWithoutScratchPaths() {
        guard Bundle.main.bundleIdentifier?.hasSuffix(".updatetest") == true,
              !(has("-storePath") && has("-libraryPath")) else { return }
        log("updatetest build refused to start: needs -storePath and -libraryPath "
            + "(build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
        exit(1)
    }

    // MARK: - Routes

    enum Route: Equatable {
        case sidebar(SidebarItem)
        case session(UUID)
        case librarySession(String)
        case record(UUID)
        case settings
        case onboarding
    }

    static let route: Route? = {
        guard let raw = value("-route") else { return nil }
        let (kind, arg): (Substring, String) = {
            guard let colon = raw.firstIndex(of: ":") else { return (Substring(raw), "") }
            return (raw[..<colon], String(raw[raw.index(after: colon)...]))
        }()
        switch (kind, arg) {
        case ("sidebar", "all"): return .sidebar(.allSessions)
        case ("sidebar", "vocabulary"): return .sidebar(.vocabulary)
        case ("person", _): return UUID(uuidString: arg).map { .sidebar(.person($0)) }
        case ("library", _) where !arg.isEmpty: return .sidebar(.libraryPerson(arg))
        case ("session", _): return UUID(uuidString: arg).map { .session($0) }
        case ("librarySession", _) where !arg.isEmpty: return .librarySession(arg)
        case ("record", _): return UUID(uuidString: arg).map { .record($0) }
        case ("settings", _): return .settings
        case ("onboarding", _): return .onboarding
        default:
            log("unknown -route \(raw)")
            return nil
        }
    }()

    static var isRouted: Bool { has("-route") }

    // MARK: - Launch-time work (app delegate)

    /// Before any window exists: appearance and fixture imports.
    @MainActor
    static func applyBeforeLaunch(store: Store) {
        if has("-windowSize") { allowWindowsLargerThanScreen() }
        switch value("-appearance") {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case nil: break
        case let other?: log("unknown -appearance \(other)")
        }
        importFixtures(store: store)
    }

    /// `-simulateModelDownloadFailure` fires once per run.
    private static let simulatedFailure = OSAllocatedUnfairLock(initialState: has("-simulateModelDownloadFailure"))

    /// True exactly once when `-simulateModelDownloadFailure` is set: the
    /// caller fails that model load as an offline download would.
    static func consumeSimulatedModelDownloadFailure() -> Bool {
        simulatedFailure.withLock { pending in
            defer { pending = false }
            if pending { log("simulating Cohere model download failure") }
            return pending
        }
    }

    @MainActor
    private static func importFixtures(store: Store) {
        let flags = ["-myName", "-importPeople", "-importVocabulary", "-importPhotos", "-asrEngine"]
        guard flags.contains(where: has) else { return }
        // Imports write store.json: only ever a scratch store.
        guard has("-storePath") else {
            log("refused: \(flags.joined(separator: "/")) need -storePath")
            return
        }
        if let name = value("-myName") {
            store.myName = name
            store.save()
        }
        if let raw = value("-asrEngine") {
            if raw == "automatic" {
                store.asrEngineChoice = nil
            } else if let engine = ASREngine(rawValue: raw) {
                store.asrEngineChoice = engine
            } else {
                log("unknown -asrEngine \(raw)")
            }
            store.save()
            log("asrEngine choice: \(store.asrEngineChoice?.rawValue ?? "automatic") → runs \(store.asrEngine.rawValue)")
        }
        if let url = path("-importPeople") {
            do {
                let result = store.importPeople(try PeopleJSON.parse(Data(contentsOf: url)))
                log("imported people: \(result.added) added, \(result.updated) updated")
            } catch {
                log("people import failed: \(error)")
            }
        }
        if let url = path("-importVocabulary") {
            do {
                let count = store.importVocabulary(try VocabularyJSON.parse(Data(contentsOf: url)))
                log("imported vocabulary: \(count) entries")
            } catch {
                log("vocabulary import failed: \(error)")
            }
        }
        if let dir = path("-importPhotos") {
            importPhotos(from: dir, store: store)
        }
    }

    @MainActor
    private static func importPhotos(from dir: URL, store: Store) {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for file in files.sorted(by: { $0.path < $1.path })
        where ["jpg", "jpeg"].contains(file.pathExtension.lowercased()) {
            let name = file.deletingPathExtension().lastPathComponent
            guard let data = try? Data(contentsOf: file),
                  let jpeg = PlatformImage.downscaledJPEG(from: data, maxDimension: 512) else {
                log("photo \(file.lastPathComponent): unreadable, skipped")
                continue
            }
            if name.caseInsensitiveCompare(store.myName) == .orderedSame {
                store.setMyPhoto(jpeg)
                log("photo \(file.lastPathComponent): my photo")
            } else if let person = store.people.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                store.setPhoto(jpeg, for: person.id)
                log("photo \(file.lastPathComponent): \(person.name)")
            } else {
                log("photo \(file.lastPathComponent): no matching person, skipped")
            }
        }
    }

    @MainActor private static var didSeed = false

    /// `-deletePersonNamed <name>`: what the sidebar's Delete… confirmation
    /// does, without the UI. Scratch locations only.
    @MainActor
    static func deletePersonIfRequested(store: Store) {
        guard let name = value("-deletePersonNamed") else { return }
        guard has("-libraryPath"), has("-storePath") else {
            log("refused: -deletePersonNamed needs both -libraryPath and -storePath")
            return
        }
        guard let person = store.people.first(where: { $0.name == name }) else {
            log("deletePersonNamed: no person \(name)")
            return
        }
        let count = store.sessions(for: person).count
        store.deletePerson(person)
        log("deletePersonNamed: deleted \(name) and \(count) session(s)")
    }

    /// `-retryFailedSessions`: what each failed session's Retry button does.
    @MainActor
    static func retryFailedIfRequested(store: Store) {
        guard has("-retryFailedSessions") else { return }
        guard has("-libraryPath"), has("-storePath") else {
            log("refused: -retryFailedSessions needs both -libraryPath and -storePath")
            return
        }
        for session in store.sessions where session.status == .failed {
            log("retrying failed session \(session.id)")
            store.startProcessing(session)
        }
    }

    /// `-seedSessionFromWAV <wav> <name>`: turn a WAV into a recorded
    /// session for that person and run the real pipeline on it, so the
    /// `.ready` transition (and its library write) runs without a microphone.
    @MainActor
    static func seedIfRequested(store: Store) {
        guard !didSeed, let args = values("-seedSessionFromWAV") else { return }
        didSeed = true
        // Seeding writes a session (and its library file): only ever into
        // scratch locations, never the real store or ~/Luxicon.
        guard has("-libraryPath"), has("-storePath") else {
            print("[seed] refused: -seedSessionFromWAV needs both -libraryPath and -storePath")
            return
        }
        let wavURL = URL(fileURLWithPath: (args[0] as NSString).expandingTildeInPath)
        let name = args[1]

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

    // MARK: - Routes (main window)

    @MainActor private static var didRoute = false

    /// Called from the main window's `.task`, so `openSettings` and the
    /// recording window's `openWindow` have a host.
    @MainActor
    static func applyRoute(store: Store, navigation: MacNavigation, openSettings: OpenSettingsAction,
                           showOnboarding: @escaping () -> Void) {
        guard !didRoute else { return }
        didRoute = true
        switch route {
        case .sidebar(let item)?:
            navigation.sidebar = item
        case .session(let id)?:
            // The sidebar first: changing it clears the session selection.
            if let record = store.sessions.first(where: { $0.id == id }) {
                navigation.sidebar = .person(record.personId)
            } else {
                log("route: no Mac session \(id)")
                navigation.sidebar = .allSessions
            }
            navigation.session = .mac(id)
        case .librarySession(let key)?:
            navigation.sidebar = .allSessions
            navigation.session = .library(sourceFile: key)
        case .record(let id)?:
            if let person = store.person(id: id) {
                navigation.requestRecording(with: person)
            } else {
                log("route: no person \(id)")
            }
        case .settings?:
            openSettings()
        case .onboarding?, nil:
            break
        }
        let presentsOnboarding = route == .onboarding
        if has("-windowSize") || has("-printWindowID") {
            // The sheet comes after sizing: resizing a window under an
            // attached sheet leaves part of it undrawn in captures.
            Task { await layOutAndReport(beforeReport: presentsOnboarding ? showOnboarding : nil) }
        } else if presentsOnboarding {
            showOnboarding()
        }
    }

    /// The route's window: Settings, the recording window, or the main one.
    @MainActor
    private static func targetWindow() -> NSWindow? {
        let visible = NSApp.windows.filter { $0.isVisible && $0.sheetParent == nil }
        func identified(_ match: (String) -> Bool) -> NSWindow? {
            visible.first { match($0.identifier?.rawValue ?? "") }
        }
        switch route {
        case .settings?: return identified { $0.localizedCaseInsensitiveContains("settings") }
        case .record?: return identified { $0.hasPrefix(MacRecordView.windowID) }
        default: return mainWindow()
        }
    }

    @MainActor
    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { ($0.identifier?.rawValue ?? "").hasPrefix(LuxiconMacApp.mainWindowID) && $0.isVisible }
    }

    @MainActor
    private static func layOutAndReport(beforeReport: (() -> Void)?) async {
        // Let the route's window open (Settings and the recording window
        // open asynchronously) and the library load.
        try? await Task.sleep(for: .seconds(1.5))
        let target = targetWindow()
        if let size = requestedSize() {
            // The recording window is fixed-size; size the main window behind it.
            let window = route.map { if case .record = $0 { return mainWindow() } else { return target } } ?? target
            if let window, let screen = window.screen ?? NSScreen.main {
                // One explicit frame, top-left on the screen. setFrame
                // doesn't constrain to the screen, so sizes larger than this
                // display (1920×1080 on a 1512×982 laptop) still lay out
                // at full size; the window server captures off-screen parts.
                let content = NSRect(origin: .zero, size: size)
                var frame = window.frameRect(forContentRect: content)
                frame.origin = NSPoint(x: screen.visibleFrame.minX, y: screen.visibleFrame.maxY - frame.height)
                window.setFrame(frame, display: true)
                log("window \(window.identifier?.rawValue ?? "?") content \(window.contentLayoutRect.size)")
            }
            if case .record? = route, let target {
                target.makeKeyAndOrderFront(nil)
            }
            try? await Task.sleep(for: .seconds(1.5))
        }
        if let beforeReport {
            beforeReport()
            try? await Task.sleep(for: .seconds(1))
        }
        for window in NSApp.windows where window.isVisible {
            log("visible window \(window.windowNumber) \(window.identifier?.rawValue ?? "?") \(window.frame)")
        }
        if has("-printWindowID") {
            if let target {
                print("WINDOW_ID \(target.windowNumber)")
            } else {
                print("WINDOW_ID none")
            }
            fflush(stdout)
        }
    }

    /// AppKit keeps a window no taller than the screen's visible frame, so
    /// on a 1512×982 laptop a 1920×1080 or 2560×1440 window would silently
    /// shrink. For QA sizes, let the frame through unchanged; the window
    /// server still captures the off-screen part.
    @MainActor
    private static func allowWindowsLargerThanScreen() {
        let original = #selector(NSWindow.constrainFrameRect(_:to:))
        let replacement = #selector(NSWindow.debugUnconstrainedFrameRect(_:to:))
        guard let a = class_getInstanceMethod(NSWindow.self, original),
              let b = class_getInstanceMethod(NSWindow.self, replacement) else { return }
        method_exchangeImplementations(a, b)
    }

    private static func requestedSize() -> NSSize? {
        guard let raw = value("-windowSize") else { return nil }
        let parts = raw.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else {
            log("bad -windowSize \(raw); expected <w>x<h>")
            return nil
        }
        return NSSize(width: parts[0], height: parts[1])
    }
}
extension NSWindow {
    /// Swapped in for `constrainFrameRect(_:to:)` by `-windowSize`.
    @objc fileprivate func debugUnconstrainedFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
#endif
