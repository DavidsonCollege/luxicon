import CoreAudio
import Foundation

/// The name of the Mac's current default input device ("MacBook Pro
/// Microphone", "AirPods Pro"), for the record window. Reading device
/// properties doesn't need microphone permission.
enum AudioInputName {
    static func current() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return nil }

        address.mSelector = kAudioObjectPropertyName
        // The property hands back a +1 CFString; Unmanaged takes ownership.
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name) == noErr,
              let name else { return nil }
        let string = name.takeRetainedValue() as String
        return string.isEmpty ? nil : string
    }
}
