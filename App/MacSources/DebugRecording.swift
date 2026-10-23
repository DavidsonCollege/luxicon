#if DEBUG
import AppKit
import Foundation
import LuxiconKit

/// DEBUG-only launch arguments for exercising the record window without a
/// person at the keyboard (or a microphone):
///
/// - `-recordWith <name>`: request a recording with that person at launch,
///   through the same path as ⌘N (needs `-libraryPath` and `-storePath`).
/// - `-noMicrophone`: open the window in its starting state; never ask for
///   or touch the microphone.
/// - `-simulateMicrophone <audio file>`: record that file (looped, in real
///   time) instead of the microphone. Live captions stay off.
/// - `-simulateSleepAfter <s>`: once `s` seconds are recorded, post
///   `NSWorkspace.willSleepNotification` (the Recorder's real observer runs
///   `onSystemSleep`), then `didWakeNotification` 2 s later.
/// - `-simulateCloseAfter <s>`: once `s` seconds are recorded, close the
///   window the way the close button does (`performClose`).
/// - `-simulateStopAfter <s>`: once `s` seconds are recorded, run Stop &
///   Transcribe.
///
/// Progress is logged to stderr with a `[record]` prefix.
@MainActor
enum DebugRecording {
    private static var arguments: [String] { ProcessInfo.processInfo.arguments }

    private static func value(after flag: String) -> String? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    private static func seconds(after flag: String) -> Double? {
        value(after: flag).flatMap(Double.init)
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("[record] \(message)\n".utf8))
    }

    static var noMicrophone: Bool { arguments.contains("-noMicrophone") }

    static func simulatedInput() -> [Float]? {
        guard let path = value(after: "-simulateMicrophone") else { return nil }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        do {
            let samples = try MeetingPipeline.loadAudio(url: url)
            log("simulated input: \(url.lastPathComponent), \(samples.count / MeetingPipeline.sampleRate) s")
            return samples
        } catch {
            log("simulated input failed to load: \(error)")
            return nil
        }
    }

    private static var didRequest = false

    static func requestRecordingIfAsked(store: Store, navigation: MacNavigation) {
        guard !didRequest, let name = value(after: "-recordWith") else { return }
        didRequest = true
        // A recording writes a session (and its library file): only ever
        // into scratch locations, never the real store or ~/Luxicon.
        guard arguments.contains("-libraryPath"), arguments.contains("-storePath") else {
            log("refused: -recordWith needs both -libraryPath and -storePath")
            return
        }
        let person: Person
        if let existing = store.people.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            person = existing
        } else {
            person = Person(name: name)
            store.people.append(person)
            store.save()
        }
        log("requesting recording with \(person.name)")
        navigation.requestRecording(with: person)
    }

    /// Fire the timed hooks once the recording has captured enough audio.
    static func runHooks(recorder: Recorder, closeGuard: WindowCloseGuard, stop: @escaping () -> Void) async {
        try? await Task.sleep(for: .seconds(1))
        if let window = closeGuard.window {
            log("window frame \(window.frame.size), content \(window.contentLayoutRect.size), "
                + "resizable \(window.styleMask.contains(.resizable)), title \"\(window.title)\"")
        }
        var pending: [(after: Double, name: String, run: () -> Void)] = []
        if let after = seconds(after: "-simulateCloseAfter") {
            pending.append((after, "close", {
                log("simulating the close button")
                closeGuard.window?.performClose(nil)
            }))
        }
        if let after = seconds(after: "-simulateStopAfter") {
            pending.append((after, "stop", {
                log("simulating Stop & Transcribe")
                stop()
            }))
        }
        if let after = seconds(after: "-simulateSleepAfter") {
            pending.append((after, "sleep", {
                log("simulating sleep (posting willSleepNotification)")
                let center = NSWorkspace.shared.notificationCenter
                center.post(name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    log("simulating wake (posting didWakeNotification)")
                    center.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
                }
            }))
        }
        pending.sort { $0.after < $1.after }
        while !pending.isEmpty, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(200))
            guard recorder.isRecording, recorder.duration >= pending[0].after else { continue }
            pending.removeFirst().run()
        }
    }
}
#endif
