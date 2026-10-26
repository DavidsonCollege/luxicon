import Foundation
import Observation
import Sparkle
import LuxiconKit

/// Owns Sparkle. Asks first: there's no `SUEnableAutomaticChecks` in
/// Info.plist, so Sparkle asks permission before its first scheduled check.
/// While the app is busy (recording window open, recording, or a session
/// processing) a scheduled update alert and the post-install relaunch wait
/// until it's idle; Check for Updates… is never held.
@MainActor @Observable
final class MacUpdater: NSObject {
    /// Mirrors `SPUUpdater.canCheckForUpdates`, for the menu item.
    private(set) var canCheckForUpdates = false

    // Set once in init; implicitly unwrapped only because the controller
    // takes `self` as its delegates, so it's created after `super.init()`.
    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private let deferral = UpdateDeferral()
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    override init() {
        super.init()
        #if DEBUG
        // Debug builds never touch the real app's Sparkle state unless asked.
        let start = DebugLaunchOptions.has("-enableUpdater")
        #else
        let start = true
        #endif
        controller = SPUStandardUpdaterController(
            startingUpdater: start, updaterDelegate: self, userDriverDelegate: self)
        // KVO fires on the thread that changed the property. SPUUpdater is
        // main-thread only, but hop rather than assume: this closure is
        // @Sendable, so it isn't main-actor isolated and can't trap.
        canCheckObservation = controller.updater.observe(
            \.canCheckForUpdates, options: [.initial, .new]
        ) { @Sendable [weak self] _, change in
            let value = change.newValue ?? false
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
        #if DEBUG
        if start, let seconds = DebugLaunchOptions.value("-checkInBackgroundAt").flatMap(Double.init) {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                DebugLaunchOptions.log("checkInBackgroundAt: scheduled-path check")
                self?.controller.updater.checkForUpdatesInBackground()
            }
        }
        #endif
    }

    /// Check for Updates…: user-initiated, so never deferred.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    func setBusy(_ busy: Bool) {
        deferral.setBusy(busy)
    }
}

extension MacUpdater: SPUUpdaterDelegate {
    #if DEBUG
    /// `-updateFeedURL <url>`: a scratch appcast instead of `SUFeedURL`.
    func feedURLString(for updater: SPUUpdater) -> String? {
        DebugLaunchOptions.value("-updateFeedURL")
    }
    #endif

    /// The relaunch after an install waits until nothing is recording or
    /// processing. Sparkle hands over `installHandler` on the main thread
    /// and it's called back on the main thread.
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        deferral.holdIfBusy { installHandler() }
    }
}

// The standard user driver (NS_SWIFT_UI_ACTOR) calls its delegate on the
// main thread, but this protocol isn't annotated, so the members are
// nonisolated and assert the main actor.
extension MacUpdater: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// A scheduled check's alert doesn't appear while busy; once idle, the
    /// update is brought forward as if the person had checked.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        MainActor.assumeIsolated {
            !deferral.holdIfBusy { [weak self] in self?.controller.updater.checkForUpdates() }
        }
    }

    /// Required when the method above returns false; nothing to do here,
    /// since the held `checkForUpdates()` does the showing once idle.
    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {}
}
