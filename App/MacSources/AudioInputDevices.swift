import CoreAudio
import Foundation
import Observation

/// A Core Audio device with at least one input stream ("MacBook Pro
/// Microphone", "Logitech BRIO", "AirPods Pro"). Reading device properties
/// doesn't need microphone permission.
struct AudioInputDevice: Identifiable, Hashable, Sendable {
    /// Valid only while the device stays connected; `uid` is the stable key.
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// Core Audio queries for input devices: the list, the system default, and
/// the input mute flag.
enum AudioInputDevices {
    /// Every connected device with input streams, sorted by name.
    static func all() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap(device(id:))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The device, if it exists and has input streams.
    static func device(id: AudioDeviceID) -> AudioInputDevice? {
        guard id != kAudioObjectUnknown, hasInputStreams(id),
              let uid = string(kAudioDevicePropertyDeviceUID, of: id) else { return nil }
        let name = string(kAudioObjectPropertyName, of: id) ?? uid
        return AudioInputDevice(id: id, uid: uid, name: name)
    }

    /// The connected input device with this UID.
    static func device(uid: String) -> AudioInputDevice? {
        all().first { $0.uid == uid }
    }

    /// The system default input device (System Settings → Sound → Input).
    static func defaultInputID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    // MARK: - Input mute flag

    /// The device's own input mute (a USB mic's mute button), on the main
    /// element. Many devices (the built-in mic, most webcams) don't have one.
    static let inputMuteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain)

    static func hasInputMute(_ id: AudioDeviceID) -> Bool {
        var address = inputMuteAddress
        return AudioObjectHasProperty(id, &address)
    }

    /// Nil when the device has no input mute flag.
    static func isInputMuted(_ id: AudioDeviceID) -> Bool? {
        guard hasInputMute(id) else { return nil }
        var address = inputMuteAddress
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    // MARK: - Helpers

    private static func string(_ selector: AudioObjectPropertySelector, of id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        // The property hands back a +1 CFString; Unmanaged takes ownership.
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        let string = value.takeRetainedValue() as String
        return string.isEmpty ? nil : string
    }
}

/// One Core Audio property listener, delivered on the main queue, removed
/// by `cancel()` (or deinit). Core Audio removes a block listener only when
/// handed the same block, so it's kept here.
final class CoreAudioPropertyListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private var block: AudioObjectPropertyListenerBlock?

    /// Nil if the object doesn't have the property or registration failed.
    init?(object: AudioObjectID, address: AudioObjectPropertyAddress, onChange: @escaping @MainActor () -> Void) {
        self.object = object
        self.address = address
        guard AudioObjectHasProperty(object, &self.address) else { return nil }
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { onChange() }
        }
        guard AudioObjectAddPropertyListenerBlock(object, &self.address, .main, block) == noErr else { return nil }
        self.block = block
    }

    func cancel() {
        guard let block else { return }
        AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        self.block = nil
    }

    deinit { cancel() }
}

/// The connected input devices and the system default, kept current as
/// devices connect and disconnect.
@Observable @MainActor
final class AudioInputDeviceList {
    private(set) var devices: [AudioInputDevice] = []
    private(set) var defaultID: AudioDeviceID?
    /// Called after `devices` or `defaultID` changes.
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var listeners: [CoreAudioPropertyListener] = []
    #if DEBUG
    /// `-simulateInputGoneAt`: devices treated as disconnected.
    @ObservationIgnored var debugHiddenIDs: Set<AudioDeviceID> = [] { didSet { refresh() } }
    #endif

    func start() {
        refresh()
        guard listeners.isEmpty else { return }
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            let address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            if let listener = CoreAudioPropertyListener(object: system, address: address, onChange: { [weak self] in
                self?.refresh()
            }) {
                listeners.append(listener)
            }
        }
    }

    func stop() {
        listeners.forEach { $0.cancel() }
        listeners = []
    }

    func refresh() {
        #if DEBUG
        let hidden = debugHiddenIDs
        #else
        let hidden: Set<AudioDeviceID> = []
        #endif
        let list = AudioInputDevices.all().filter { !hidden.contains($0.id) }
        let defaultID = AudioInputDevices.defaultInputID().flatMap { hidden.contains($0) ? list.first?.id : $0 }
        guard list != devices || defaultID != self.defaultID else { return }
        devices = list
        self.defaultID = defaultID
        onChange?()
    }

    func device(id: AudioDeviceID?) -> AudioInputDevice? {
        guard let id else { return nil }
        return devices.first { $0.id == id }
    }
}
