import Testing
@testable import LuxiconKit

/// `UpdateDeferral` holds the Mac auto-updater's alert and relaunch while a
/// recording or transcription is in progress, then runs them once idle.
@MainActor @Suite struct UpdateDeferralTests {
    private final class Log { var entries: [String] = [] }

    @Test func notBusyDoesNotHold() {
        let deferral = UpdateDeferral()
        let log = Log()
        #expect(deferral.holdIfBusy { log.entries.append("a") } == false)
        deferral.setBusy(true)
        deferral.setBusy(false)
        #expect(log.entries.isEmpty)
    }

    @Test func busyHoldsUntilIdle() {
        let deferral = UpdateDeferral()
        let log = Log()
        deferral.setBusy(true)
        #expect(deferral.holdIfBusy { log.entries.append("a") } == true)
        #expect(log.entries.isEmpty)
        deferral.setBusy(false)
        #expect(log.entries == ["a"])
    }

    @Test func runsInOrderOnce() {
        let deferral = UpdateDeferral()
        let log = Log()
        deferral.setBusy(true)
        _ = deferral.holdIfBusy { log.entries.append("a") }
        _ = deferral.holdIfBusy { log.entries.append("b") }
        deferral.setBusy(false)
        #expect(log.entries == ["a", "b"])
        deferral.setBusy(true)
        deferral.setBusy(false)
        #expect(log.entries == ["a", "b"])
    }

    @Test func repeatedBusyDoesNotRun() {
        let deferral = UpdateDeferral()
        let log = Log()
        deferral.setBusy(true)
        _ = deferral.holdIfBusy { log.entries.append("a") }
        deferral.setBusy(true)
        #expect(log.entries.isEmpty)
        #expect(deferral.isBusy)
    }

    @Test func idleToIdleDoesNotRun() {
        let deferral = UpdateDeferral()
        let log = Log()
        deferral.setBusy(false)
        #expect(log.entries.isEmpty)
        #expect(!deferral.isBusy)
    }
}
