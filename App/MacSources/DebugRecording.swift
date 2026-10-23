#if DEBUG
import AppKit
import Foundation
import LuxiconKit

/// DEBUG-only launch arguments (parsed by `DebugLaunchOptions`) for
/// exercising the record window without a person at the keyboard (or a
/// microphone):
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
/// - `-simulateQuitAfter <s>`: once `s` seconds are recorded, quit (⌘Q's
///   `NSApp.terminate`).
/// - `-answerPromptWith save|discard|keep`: answer the "Stop and save this
///   recording?" prompt 1 s after it appears.
/// - `-simulateSaveFailure`: make saving fail (a file already sits where
///   the finished audio would be moved).
/// - `-simulatePermissionDelay <s>` with `-simulateEarlyClose`: the start
///   waits `s` seconds (standing in for the permission prompt) while the
///   window is closed right after it opens.
///
/// Timed hooks count recorded seconds, which hold still after a stop, so
/// a hook with the same time as a stop fires right after it. With
/// `-timedHooksUseWallClock` they count wall-clock seconds since the
/// recording started instead, so they can fire while off the record.
///
/// Microphone picker and mute hooks count WALL-CLOCK seconds since the
/// recording started (recorded seconds stand still while off the record):
///
/// - `-simulateMuteAt <s>` / `-simulateUnmuteAt <s>`: mute / unmute the
///   source(s) named by `-simulateMuteSource system|device|both` (default
///   `system`). The system source goes through the real API
///   (`AVAudioApplication.setInputMuted` → the registered handler); the
///   device source is injected where the device's mute flag would report.
/// - `-simulateStartMuted system|device|both`: those sources are muted
///   before the recording starts.
/// - `-simulateManualOffAt <s>` / `-simulateManualResumeAt <s>`: the
///   "Go Off the Record" button / the overlay's Resume.
/// - `-selectInputNamed <name> <s>`: pick that input device in the picker.
/// - `-simulateInputGoneAt <s>`: treat the captured device as unplugged.
///
/// With any of these, a once-a-second `[record] tick` line logs the wall
/// time, recorded duration, off-record state, and captured device. The
/// picked microphone is saved next to the scratch store
/// (`debug-input-device.plist`), never in the real app's defaults.
///
/// Progress is logged to stderr with a `[record]` prefix.
@MainActor
enum DebugRecording {
    private static func value(after flag: String) -> String? {
        DebugLaunchOptions.value(flag)
    }

    private static func seconds(after flag: String) -> Double? {
        value(after: flag).flatMap(Double.init)
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("[record] \(message)\n".utf8))
    }

    static var noMicrophone: Bool { DebugLaunchOptions.has("-noMicrophone") }

    private static func muteSources(_ raw: String?) -> [OffRecordState.MuteSource] {
        switch raw {
        case nil: return []
        case "both": return [.system, .device]
        case let raw?:
            if let source = OffRecordState.MuteSource(rawValue: raw) { return [source] }
            log("unknown mute source \(raw); expected system, device, or both")
            return []
        }
    }

    /// `-simulateStartMuted`: sources muted before the recording starts.
    static var startMutedSources: [OffRecordState.MuteSource] {
        muteSources(value(after: "-simulateStartMuted"))
    }

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

    static func answerPromptIfAsked(_ answer: @escaping (RecordingCloseAnswer) -> Void) {
        guard let raw = value(after: "-answerPromptWith"),
              let choice = RecordingCloseAnswer(rawValue: raw) else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            log("answering the prompt: \(choice.rawValue)")
            answer(choice)
        }
    }

    static func permissionDelayIfAsked() async {
        guard let delay = seconds(after: "-simulatePermissionDelay") else { return }
        log("simulating a \(delay) s permission prompt")
        try? await Task.sleep(for: .seconds(delay))
    }

    static func blockSaveIfAsked(store: Store, sessionId: UUID) {
        guard DebugLaunchOptions.has("-simulateSaveFailure") else { return }
        let blocker = store.inProgressAudioURL(id: sessionId)
            .deletingLastPathComponent()
            .appendingPathComponent("\(sessionId.uuidString).wav")
        FileManager.default.createFile(atPath: blocker.path, contents: Data("blocker".utf8))
        log("simulating a save failure: blocker at \(blocker.lastPathComponent)")
    }

    private static var didRequest = false

    static func requestRecordingIfAsked(store: Store, navigation: MacNavigation) {
        guard !didRequest, let name = value(after: "-recordWith") else { return }
        didRequest = true
        // A recording writes a session (and its library file): only ever
        // into scratch locations, never the real store or ~/Luxicon.
        guard DebugLaunchOptions.has("-libraryPath"), DebugLaunchOptions.has("-storePath") else {
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
        if DebugLaunchOptions.has("-simulateEarlyClose") {
            log("simulating the close button before recording starts")
            closeGuard.window?.performClose(nil)
        }
        var pending: [(after: Double, name: String, run: () -> Void)] = []
        if let after = seconds(after: "-simulateStopAfter") {
            pending.append((after, "stop", {
                log("simulating Stop & Transcribe")
                stop()
            }))
        }
        if let after = seconds(after: "-simulateCloseAfter") {
            pending.append((after, "close", {
                log("simulating the close button")
                closeGuard.window?.performClose(nil)
            }))
        }
        if let after = seconds(after: "-simulateQuitAfter") {
            pending.append((after, "quit", {
                log("simulating ⌘Q")
                // From a run-loop timer, like a real ⌘Q event: calling
                // terminate inside this main-queue task would block the
                // queue for the whole held quit (`.terminateLater`).
                NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
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
        // Stable by time: stop is listed before close for equal times.
        pending = pending.enumerated()
            .sorted { ($0.element.after, $0.offset) < ($1.element.after, $1.offset) }
            .map(\.element)
        let wallClock = DebugLaunchOptions.has("-timedHooksUseWallClock")
        var startedAt: ContinuousClock.Instant?
        while !pending.isEmpty, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(200))
            if wallClock {
                if startedAt == nil, recorder.isRecording { startedAt = .now }
                guard let startedAt else { continue }
                let elapsed = ContinuousClock.now - startedAt
                guard Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                        >= pending[0].after else { continue }
            } else {
                guard recorder.duration > 0, recorder.duration >= pending[0].after else { continue }
            }
            pending.removeFirst().run()
        }
    }

    private static let inputHookFlags = [
        "-simulateMuteAt", "-simulateUnmuteAt", "-simulateStartMuted", "-simulateManualOffAt",
        "-simulateManualResumeAt", "-selectInputNamed", "-simulateInputGoneAt",
    ]

    /// The picker and mute hooks, timed in wall-clock seconds from the
    /// start of the recording.
    static func runInputHooks(input: RecordingInputController, recorder: Recorder) async {
        guard inputHookFlags.contains(where: DebugLaunchOptions.has) else { return }
        for device in input.deviceList.devices {
            log("input device \(device.id) \(device.name) uid=\(device.uid) "
                + "muteProperty=\(AudioInputDevices.hasInputMute(device.id))")
        }
        while !recorder.isRecording, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let start = ContinuousClock.now
        func elapsed() -> Double {
            let d = ContinuousClock.now - start
            return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }
        let sources = muteSources(value(after: "-simulateMuteSource") ?? "system")
        var pending: [(at: Double, run: () -> Void)] = []
        if let at = seconds(after: "-simulateMuteAt") {
            pending.append((at, {
                log("simulating mute (\(sources.map(\.rawValue).joined(separator: "+")))")
                sources.forEach { input.debugSimulateMute($0, muted: true) }
            }))
        }
        if let at = seconds(after: "-simulateUnmuteAt") {
            pending.append((at, {
                log("simulating unmute (\(sources.map(\.rawValue).joined(separator: "+")))")
                sources.forEach { input.debugSimulateMute($0, muted: false) }
            }))
        }
        if let at = seconds(after: "-simulateManualOffAt") {
            pending.append((at, {
                log("simulating Go Off the Record")
                input.goOffRecord()
            }))
        }
        if let at = seconds(after: "-simulateManualResumeAt") {
            pending.append((at, {
                log("simulating Resume (enabled: \(input.offRecord.canManuallyResume))")
                // The button is disabled while muted; a click can't land.
                if input.offRecord.canManuallyResume || input.offRecord.shouldCapture { input.resume() }
            }))
        }
        if let args = DebugLaunchOptions.values("-selectInputNamed"), let at = Double(args[1]) {
            let name = args[0]
            pending.append((at, {
                if let device = input.deviceList.devices.first(where: {
                    $0.name.caseInsensitiveCompare(name) == .orderedSame
                }) {
                    log("simulating picking \(device.name)")
                    input.select(device)
                } else {
                    log("selectInputNamed: no input device named \(name)")
                }
            }))
        }
        if let at = seconds(after: "-simulateInputGoneAt") {
            pending.append((at, {
                log("simulating the captured device disconnecting")
                input.debugDisconnectCurrent()
            }))
        }
        pending = pending.enumerated()
            .sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }
            .map(\.element)
        var nextTick = 0.0
        while recorder.isRecording, !Task.isCancelled {
            let now = elapsed()
            while let first = pending.first, now >= first.at {
                pending.removeFirst().run()
            }
            if now >= nextTick {
                nextTick += 1
                let mode: String = switch input.offRecord.mode {
                case .recording: "recording"
                case .offRecord(reason: .manual): "off(manual)"
                case .offRecord(reason: .muted): "off(muted)"
                }
                log("tick wall=\(String(format: "%.1f", now)) duration=\(String(format: "%.1f", recorder.duration)) "
                    + "state=\(mode) overlay=\(input.isOffRecord) paused=\(recorder.isPaused) "
                    + "resumeEnabled=\(input.offRecord.canManuallyResume) "
                    + "device=\(input.currentDevice?.name ?? "none")"
                    + (input.deviceNote.map { " note=\"\($0)\"" } ?? ""))
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
#endif
