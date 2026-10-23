import CoreAudio
import Foundation
import Observation
import LuxiconKit

/// The microphone the user last picked in the record window, by UID (stable
/// across reconnects; `AudioDeviceID`s aren't). The name is kept only for
/// the "isn't connected" note.
enum InputDevicePreference {
    static let uidKey = "macInputDeviceUID"
    static let nameKey = "macInputDeviceName"

    static var uid: String? { read(uidKey) }
    static var name: String? { read(nameKey) }

    static func save(_ device: AudioInputDevice) {
        write([uidKey: device.uid, nameKey: device.name])
    }

    private static func read(_ key: String) -> String? {
        #if DEBUG
        if let url = debugFile {
            return (NSDictionary(contentsOf: url) as? [String: String])?[key]
        }
        #endif
        return UserDefaults.standard.string(forKey: key)
    }

    private static func write(_ values: [String: String]) {
        #if DEBUG
        if let url = debugFile {
            var dict = (NSDictionary(contentsOf: url) as? [String: String]) ?? [:]
            dict.merge(values) { $1 }
            (dict as NSDictionary).write(to: url, atomically: true)
            return
        }
        #endif
        for (key, value) in values { UserDefaults.standard.set(value, forKey: key) }
    }

    #if DEBUG
    /// Scratch-store runs keep the choice next to the scratch store, so
    /// automation never changes the real app's saved microphone.
    private static var debugFile: URL? {
        DebugLaunchOptions.path("-storePath")?.appendingPathComponent("debug-input-device.plist")
    }
    #endif
}

/// The record window's input side: which microphone is captured (the
/// picker, the saved choice, falling back when a device is missing or
/// unplugged) and whether the recording is off the record (by hand or
/// because the mic is muted). It drives the `Recorder` through its explicit
/// `pause()` / `resume()` — mute-driven resumes go through the same call a
/// Resume click does, so the recorder's "off the record never resumes on
/// its own" invariant still holds.
@Observable @MainActor
final class RecordingInputController {
    let deviceList = AudioInputDeviceList()
    private(set) var offRecord = OffRecordState()
    /// The device being captured from (read back from the input unit), or
    /// before the recording starts, the one it will use.
    private(set) var currentDeviceID: AudioDeviceID?
    /// One line under the picker: a saved or captured mic went missing.
    private(set) var deviceNote: String?
    /// The recorder has been started (possibly off the record).
    private(set) var hasStarted = false
    /// The off-record screen is up: the state says so, or a resume failed
    /// (the recorder is still paused). Kept as-is once the recording stops,
    /// so the window doesn't flash back to the live view while it closes.
    private(set) var isOffRecord = false

    @ObservationIgnored private let muteMonitor = InputMuteMonitor()
    @ObservationIgnored private weak var recorder: Recorder?
    /// The user's pick is connected: capture is pinned to it. Otherwise
    /// capture uses (and follows) the system default.
    @ObservationIgnored private var pinnedID: AudioDeviceID?
    /// Last known name of the current device, for the note after it's gone.
    @ObservationIgnored private var currentDeviceName: String?
    @ObservationIgnored private var isStopped = false

    var currentDevice: AudioInputDevice? { deviceList.device(id: currentDeviceID) }

    /// Window opened: list devices and pick the one the recording will use.
    func prepare() {
        deviceList.onChange = { [weak self] in self?.devicesChanged() }
        deviceList.start()
        resolveStartingDevice()
    }

    /// Start `recorder` on the resolved device, already off the record if
    /// the mic is muted right now.
    func start(recorder: Recorder, writingTo fileURL: URL) throws {
        self.recorder = recorder
        if let pinnedID {
            try? recorder.setInputDevice(pinnedID)
        }
        muteMonitor.onChange = { [weak self] source, muted in
            self?.apply(.muteChanged(source: source, muted: muted))
        }
        muteMonitor.start()
        muteMonitor.watchDevice(currentDeviceID)
        #if DEBUG
        for source in DebugRecording.startMutedSources {
            log("simulating a \(source.rawValue) mute before the recording starts")
            muteMonitor.debugSimulate(source, muted: true)
        }
        #endif
        offRecord = OffRecordState(mutedSources: muteMonitor.mutedSources)
        if offRecord.shouldCapture {
            try recorder.start(writingTo: fileURL)
        } else {
            log("microphone muted at start: recording starts off the record")
            try recorder.startOffRecord(writingTo: fileURL)
        }
        hasStarted = true
        isOffRecord = recorder.isPaused
        refresh()
    }

    /// Recording over (saved, discarded, or the window closed).
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        muteMonitor.stop()
        deviceList.stop()
        deviceList.onChange = nil
    }

    // MARK: - Off the record

    /// "Go Off the Record".
    func goOffRecord() { apply(.manualPause) }

    /// The overlay's Resume. Also retries a resume that failed (state says
    /// record, recorder still paused).
    func resume() { apply(.manualResume) }

    private func apply(_ event: OffRecordState.Event) {
        guard !isStopped else { return }
        offRecord.apply(event)
        syncRecorder()
    }

    /// Make the recorder match the state, through its explicit calls only.
    private func syncRecorder() {
        guard let recorder, recorder.isRecording else { return }
        if offRecord.shouldCapture {
            if recorder.isPaused {
                recorder.resume()
                log(recorder.isPaused
                    ? "resume failed; still off the record"
                    : "back on the record at \(String(format: "%.1f", recorder.duration)) s")
            }
        } else if !recorder.isPaused {
            recorder.pause()
            log("off the record (\(offRecord.mode == .offRecord(reason: .muted) ? "muted" : "manual")) "
                + "at \(String(format: "%.1f", recorder.duration)) s")
        }
        isOffRecord = recorder.isPaused
    }

    // MARK: - Devices

    /// The picker: remember the choice and capture from it (seamlessly,
    /// mid-recording).
    func select(_ device: AudioInputDevice) {
        guard device.id != currentDeviceID || pinnedID == nil else { return }
        InputDevicePreference.save(device)
        pinnedID = device.id
        deviceNote = nil
        if let recorder, recorder.isRecording {
            do {
                try recorder.setInputDevice(device.id)
            } catch {
                deviceNote = "Couldn't switch to \(device.name): \(error.localizedDescription)"
                log("switch to \(device.name) failed: \(error.localizedDescription)")
                refresh()
                return
            }
        }
        log("selected \(device.name)")
        setCurrent(device.id)
    }

    /// Poll the input unit's actual device (it changes under us when the
    /// default changes or Core Audio reroutes).
    func refresh() {
        guard hasStarted, !isStopped, let recorder, recorder.isRecording else { return }
        setCurrent(recorder.currentInputDeviceID ?? pinnedID ?? deviceList.defaultID)
    }

    private func setCurrent(_ id: AudioDeviceID?) {
        if let device = deviceList.device(id: id) { currentDeviceName = device.name }
        guard id != currentDeviceID else { return }
        currentDeviceID = id
        log("capturing from \(currentDeviceName ?? "unknown device") (\(id.map(String.init) ?? "none"))")
        guard hasStarted else { return }
        // A muted device replaced mid-span: stay off the record (by hand)
        // rather than resume on the new device.
        if offRecord.mutedSources.contains(.device) {
            log("captured device changed while its mute was on: staying off the record until Resume")
        }
        apply(.inputDeviceChanged)
        muteMonitor.watchDevice(id)
    }

    private func resolveStartingDevice() {
        let defaultID = deviceList.defaultID
        if let uid = InputDevicePreference.uid {
            if let saved = deviceList.devices.first(where: { $0.uid == uid }) {
                pinnedID = saved.id
                deviceNote = nil
                setCurrent(saved.id)
            } else {
                pinnedID = nil
                deviceNote = Self.missingNote(InputDevicePreference.name, using: deviceList.device(id: defaultID)?.name)
                setCurrent(defaultID)
            }
        } else {
            pinnedID = nil
            setCurrent(defaultID)
        }
    }

    private func devicesChanged() {
        guard !isStopped else { return }
        // Before the recording starts, a saved mic plugged in (or pulled)
        // changes which one it will use.
        guard hasStarted else {
            resolveStartingDevice()
            return
        }
        guard let recorder, recorder.isRecording, let current = currentDeviceID,
              deviceList.device(id: current) == nil else { return }
        // The captured device is gone: carry on with the system default.
        let lostName = currentDeviceName
        pinnedID = nil
        let fallback = deviceList.defaultID
        deviceNote = Self.missingNote(lostName, using: deviceList.device(id: fallback)?.name)
        log("\(lostName ?? "input device") disconnected; falling back to the default")
        if let fallback {
            try? recorder.setInputDevice(fallback)
        }
        setCurrent(fallback)
    }

    static func missingNote(_ savedName: String?, using defaultName: String?) -> String {
        let using = defaultName.map { "using \($0)" } ?? "no other microphone is available"
        if let savedName {
            return "\(savedName) isn’t connected — \(using)."
        }
        return "Your saved microphone isn’t connected — \(using)."
    }

    private func log(_ message: String) {
        #if DEBUG
        DebugRecording.log(message)
        #endif
    }

    #if DEBUG
    func debugSimulateMute(_ source: OffRecordState.MuteSource, muted: Bool) {
        muteMonitor.debugSimulate(source, muted: muted)
    }

    /// `-simulateInputGoneAt`: treat the captured device as unplugged.
    func debugDisconnectCurrent() {
        guard let id = currentDeviceID else { return }
        deviceList.debugHiddenIDs.insert(id)
    }
    #endif
}
