import AVFAudio
import CoreAudio
import Foundation
import LuxiconKit

/// Watches both input-mute signals while a recording is open and reports
/// each change on the main actor:
///
/// - `.system`: the app's input mute, toggled by an AirPods / Beats stem
///   press or a headset's mute (`AVAudioApplication`). On macOS the app
///   implements muting itself: the system calls the handler registered
///   with `setInputMuteStateChangeHandler`, and the handler must mute all
///   input until it's called again, returning true once it has. Going off
///   the record (capture stopped) is how Luxicon mutes, so the handler
///   reports and returns true. The handler is the authoritative signal —
///   `inputMuteStateChangeNotification` is only posted while a record
///   session is active, so it's observed as a backup (state is idempotent).
/// - `.device`: the captured device's own mute flag (`kAudioDevicePropertyMute`,
///   input scope, main element), e.g. a USB mic's mute button. Re-registered
///   whenever the captured device changes; devices without the property
///   simply aren't watched (reported unmuted).
@MainActor
final class InputMuteMonitor {
    typealias Source = OffRecordState.MuteSource

    var onChange: ((Source, Bool) -> Void)?
    private var deviceListener: CoreAudioPropertyListener?
    private(set) var watchedDevice: AudioDeviceID?
    private var notificationObserver: NSObjectProtocol?
    private var isRunning = false
    private var lastReported: [Source: Bool] = [:]
    #if DEBUG
    /// `-simulateMuteAt … device`: stands in for the device's flag.
    private var debugDeviceMuted: Bool?
    #endif

    /// The system input mute right now (true if the app's input is muted).
    var isSystemMuted: Bool { AVAudioApplication.shared.isInputMuted }

    /// The watched device's mute flag right now (false without one).
    var isDeviceMuted: Bool {
        #if DEBUG
        if let debugDeviceMuted { return debugDeviceMuted }
        #endif
        return watchedDevice.flatMap(AudioInputDevices.isInputMuted) ?? false
    }

    /// The sources muted right now, for a recording's starting state.
    var mutedSources: Set<Source> {
        var sources: Set<Source> = []
        if isSystemMuted { sources.insert(.system) }
        if isDeviceMuted { sources.insert(.device) }
        return sources
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        do {
            try AVAudioApplication.shared.setInputMuteStateChangeHandler { [weak self] shouldMute in
                // Can arrive synchronously inside `setInputMuted` or on
                // another thread: hop to main, never re-enter the caller.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.report(.system, muted: shouldMute) }
                }
                return true
            }
        } catch {
            log("system mute handler not registered: \(error.localizedDescription)")
        }
        notificationObserver = NotificationCenter.default.addObserver(
            forName: AVAudioApplication.inputMuteStateChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let muted = (note.userInfo?[AVAudioApplication.muteStateKey] as? NSNumber)?.boolValue else { return }
            MainActor.assumeIsolated { self?.report(.system, muted: muted) }
        }
    }

    /// Watch `id`'s mute flag instead of the previous device's, and report
    /// its current state (a device switch can mute or unmute).
    func watchDevice(_ id: AudioDeviceID?) {
        guard isRunning, id != watchedDevice || deviceListener == nil else { return }
        deviceListener?.cancel()
        deviceListener = nil
        watchedDevice = id
        #if DEBUG
        debugDeviceMuted = nil  // a simulated mute belonged to the old device
        #endif
        if let id {
            deviceListener = CoreAudioPropertyListener(
                object: id, address: AudioInputDevices.inputMuteAddress
            ) { [weak self] in
                guard let self else { return }
                self.report(.device, muted: self.isDeviceMuted)
            }
        }
        log("watching mute on device \(id.map(String.init) ?? "none"): "
            + (deviceListener == nil ? "no mute property" : "mute property present"))
        // Always report the new device's flag, even if it matches the old one's.
        lastReported[.device] = nil
        report(.device, muted: isDeviceMuted)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        try? AVAudioApplication.shared.setInputMuteStateChangeHandler(nil)
        if let notificationObserver {
            NotificationCenter.default.removeObserver(notificationObserver)
        }
        notificationObserver = nil
        deviceListener?.cancel()
        deviceListener = nil
        watchedDevice = nil
        lastReported = [:]
        onChange = nil
    }

    private func report(_ source: Source, muted: Bool) {
        guard isRunning, lastReported[source] != muted else { return }
        lastReported[source] = muted
        log("\(source.rawValue) mute: \(muted ? "muted" : "unmuted")")
        onChange?(source, muted)
    }

    private func log(_ message: String) {
        #if DEBUG
        DebugRecording.log(message)
        #endif
    }

    #if DEBUG
    /// Simulate a mute change. The system source goes through the real API
    /// (`setInputMuted` → the registered handler); the device source can't
    /// be flipped without changing real hardware, so it's injected here.
    func debugSimulate(_ source: Source, muted: Bool) {
        switch source {
        case .system:
            do {
                try AVAudioApplication.shared.setInputMuted(muted)
            } catch {
                log("setInputMuted(\(muted)) failed: \(error.localizedDescription)")
            }
        case .device:
            debugDeviceMuted = muted
            report(.device, muted: muted)
        }
    }
    #endif
}
