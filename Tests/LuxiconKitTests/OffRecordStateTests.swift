import Testing
@testable import LuxiconKit

@Suite struct OffRecordStateTests {
    @Test func startsRecordingWhenNothingIsMuted() {
        let state = OffRecordState()
        #expect(state.mode == .recording)
        #expect(state.shouldCapture)
        #expect(!state.canManuallyResume)
    }

    @Test func manualPauseAndResume() {
        var state = OffRecordState()
        state.apply(.manualPause)
        #expect(state.mode == .offRecord(reason: .manual))
        #expect(!state.shouldCapture)
        #expect(state.canManuallyResume)

        state.apply(.manualResume)
        #expect(state.mode == .recording)
        #expect(state.shouldCapture)
    }

    @Test func muteThenUnmuteResumes() {
        var state = OffRecordState()
        state.apply(.muteChanged(source: .system, muted: true))
        #expect(state.mode == .offRecord(reason: .muted))
        #expect(!state.shouldCapture)

        state.apply(.muteChanged(source: .system, muted: false))
        #expect(state.mode == .recording)
        #expect(state.shouldCapture)
    }

    @Test func deviceMuteAloneAlsoGoesOffTheRecord() {
        var state = OffRecordState()
        state.apply(.muteChanged(source: .device, muted: true))
        #expect(state.mode == .offRecord(reason: .muted))
        state.apply(.muteChanged(source: .device, muted: false))
        #expect(state.mode == .recording)
    }

    @Test func manualOffThenMuteThenUnmuteStaysManual() {
        var state = OffRecordState()
        state.apply(.manualPause)
        state.apply(.muteChanged(source: .system, muted: true))
        #expect(state.mode == .offRecord(reason: .manual))
        state.apply(.muteChanged(source: .system, muted: false))
        #expect(state.mode == .offRecord(reason: .manual))
        #expect(!state.shouldCapture)
        #expect(state.canManuallyResume)
    }

    @Test func manualPauseWhileMutedIsNotEndedByUnmute() {
        var state = OffRecordState()
        state.apply(.muteChanged(source: .device, muted: true))
        state.apply(.manualPause)
        #expect(state.mode == .offRecord(reason: .manual))
        state.apply(.muteChanged(source: .device, muted: false))
        #expect(state.mode == .offRecord(reason: .manual))
    }

    @Test func twoSourcesBothMustUnmute() {
        var state = OffRecordState()
        state.apply(.muteChanged(source: .system, muted: true))
        state.apply(.muteChanged(source: .device, muted: true))
        #expect(state.mode == .offRecord(reason: .muted))

        state.apply(.muteChanged(source: .system, muted: false))
        #expect(state.mode == .offRecord(reason: .muted))
        #expect(!state.shouldCapture)

        state.apply(.muteChanged(source: .device, muted: false))
        #expect(state.mode == .recording)
        #expect(state.shouldCapture)
    }

    @Test func repeatedMuteEventsFromOneSourceAreIdempotent() {
        var state = OffRecordState()
        state.apply(.muteChanged(source: .system, muted: true))
        state.apply(.muteChanged(source: .system, muted: true))
        state.apply(.muteChanged(source: .system, muted: false))
        #expect(state.mode == .recording)
    }

    @Test func startingMutedStartsOffTheRecord() {
        let state = OffRecordState(mutedSources: [.device])
        #expect(state.mode == .offRecord(reason: .muted))
        #expect(!state.shouldCapture)
        #expect(!state.canManuallyResume)

        var unmuted = state
        unmuted.apply(.muteChanged(source: .device, muted: false))
        #expect(unmuted.mode == .recording)
    }

    @Test func manualResumeIsDisabledWhileMuted() {
        var state = OffRecordState()
        state.apply(.muteChanged(source: .system, muted: true))
        #expect(!state.canManuallyResume)

        // A Resume that slips through anyway changes nothing: resuming a
        // muted mic would only record silence.
        state.apply(.manualResume)
        #expect(state.mode == .offRecord(reason: .muted))
        #expect(!state.shouldCapture)
    }

    @Test func manualResumeWhileManualAndMutedHandsOverToMute() {
        // Off the record by hand, then muted: Resume ends the manual span,
        // and the still-muted mic keeps it off until unmute.
        var state = OffRecordState()
        state.apply(.manualPause)
        state.apply(.muteChanged(source: .system, muted: true))
        #expect(state.canManuallyResume)
        state.apply(.manualResume)
        #expect(state.mode == .offRecord(reason: .muted))
        #expect(!state.canManuallyResume)
        #expect(!state.shouldCapture)

        state.apply(.muteChanged(source: .system, muted: false))
        #expect(state.mode == .recording)
    }

    @Test func manualPauseIsIdempotent() {
        var state = OffRecordState()
        state.apply(.manualPause)
        state.apply(.manualPause)
        state.apply(.manualResume)
        #expect(state.mode == .recording)
    }

    @Test func manualResumeWhileRecordingIsNoOp() {
        var state = OffRecordState()
        state.apply(.manualResume)
        #expect(state.mode == .recording)
    }

    @Test func deviceChangeWhileDeviceMutedStaysOffByHand() {
        // A muted USB mic unplugged (or replaced by a new default) mustn't
        // resume capture on another mic mid-conversation: the span becomes
        // a manual one, ended only by Resume.
        var state = OffRecordState()
        state.apply(.muteChanged(source: .device, muted: true))
        state.apply(.inputDeviceChanged)
        #expect(state.mode == .offRecord(reason: .manual))
        #expect(!state.mutedSources.contains(.device))
        #expect(state.canManuallyResume)

        // The new device reports unmuted: still off until Resume.
        state.apply(.muteChanged(source: .device, muted: false))
        #expect(state.mode == .offRecord(reason: .manual))
        state.apply(.manualResume)
        #expect(state.mode == .recording)
    }

    @Test func deviceChangeWhileSystemMutedKeepsWaitingForUnmute() {
        // The system mute follows the app, not the device.
        var state = OffRecordState()
        state.apply(.muteChanged(source: .system, muted: true))
        state.apply(.inputDeviceChanged)
        #expect(state.mode == .offRecord(reason: .muted))
        state.apply(.muteChanged(source: .system, muted: false))
        #expect(state.mode == .recording)
    }

    @Test func deviceChangeWhileRecordingChangesNothing() {
        var state = OffRecordState()
        state.apply(.inputDeviceChanged)
        #expect(state.mode == .recording)
    }

    @Test func isMutedReflectsAnySource() {
        var state = OffRecordState()
        #expect(!state.isMuted)
        state.apply(.muteChanged(source: .device, muted: true))
        #expect(state.isMuted)
        state.apply(.muteChanged(source: .device, muted: false))
        #expect(!state.isMuted)
    }
}
