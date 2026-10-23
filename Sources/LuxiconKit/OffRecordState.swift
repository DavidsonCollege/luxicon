/// Whether a recording is capturing or "off the record", and why.
///
/// Two things take a recording off the record: the user ("Go off the
/// record", ended only by their Resume) and a muted microphone (ended by
/// unmuting). They're tracked separately so each ends only its own span:
///
/// - Unmuting never ends a manual span, even one that began while muted.
/// - Resume ends a manual span, but while the mic is still muted the
///   recording stays off (as `.muted`) — resuming would only record silence
///   — and comes back on its own at unmute. A muted span can't be resumed
///   by hand at all (`canManuallyResume`).
/// - Mute sources are independent: off while ANY source is muted.
/// - The captured device changing while its own mute flag is set (the muted
///   USB mic unplugged, a new default taking over) never resumes capture on
///   the new device: the span becomes a manual one, ended only by Resume.
public struct OffRecordState: Equatable, Sendable {
    /// Where a mute signal came from.
    public enum MuteSource: String, Hashable, Sendable, CaseIterable {
        /// The system's input mute (AirPods stem press, headset mute).
        case system
        /// The input device's own mute flag (a USB mic's mute button).
        case device
    }

    public enum Reason: Equatable, Sendable {
        case manual
        case muted
    }

    public enum Mode: Equatable, Sendable {
        case recording
        case offRecord(reason: Reason)
    }

    public enum Event: Equatable, Sendable {
        case manualPause
        case manualResume
        case muteChanged(source: MuteSource, muted: Bool)
        /// Capture moved to another input device (picked, unplugged, or a
        /// new default). The old device's mute flag no longer applies.
        case inputDeviceChanged
    }

    public private(set) var mutedSources: Set<MuteSource>
    public private(set) var isManuallyOff: Bool

    /// `mutedSources`: the sources already muted when recording starts — a
    /// recording that starts muted starts off the record.
    public init(mutedSources: Set<MuteSource> = []) {
        self.mutedSources = mutedSources
        self.isManuallyOff = false
    }

    public var isMuted: Bool { !mutedSources.isEmpty }

    /// A manual span wins: its copy and its Resume stay up until the user
    /// ends it, whatever the mic does meanwhile.
    public var mode: Mode {
        if isManuallyOff { return .offRecord(reason: .manual) }
        if isMuted { return .offRecord(reason: .muted) }
        return .recording
    }

    /// Whether audio should be flowing into the recording right now.
    public var shouldCapture: Bool { mode == .recording }

    /// Whether the off-record screen's Resume button is enabled.
    public var canManuallyResume: Bool { mode == .offRecord(reason: .manual) }

    public mutating func apply(_ event: Event) {
        switch event {
        case .manualPause:
            isManuallyOff = true
        case .manualResume:
            isManuallyOff = false
        case .muteChanged(let source, let muted):
            if muted {
                mutedSources.insert(source)
            } else {
                mutedSources.remove(source)
            }
        case .inputDeviceChanged:
            if mutedSources.remove(.device) != nil {
                isManuallyOff = true
            }
        }
    }
}
