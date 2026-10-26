import AppKit
import SwiftUI

/// Mac entry point: the main split-view window, Settings, and menus.
@main
struct LuxiconMacApp: App {
    static let mainWindowID = "main"

    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Luxicon", id: Self.mainWindowID) {
            MacRootView()
                .environment(appDelegate.store)
                .environment(appDelegate.library)
                .environment(appDelegate.navigation)
        }
        .defaultSize(width: 1200, height: 800)
        // Open on every launch, even when the last session ended with the
        // window closed (restoration would otherwise bring back zero windows).
        .defaultLaunchBehavior(.presented)
        .commands {
            MacCommands(store: appDelegate.store, library: appDelegate.library,
                        navigation: appDelegate.navigation, updater: appDelegate.updater)
        }

        // One recording at a time, in its own fixed-size window. Never
        // restored or opened at launch; ⌘N and the record buttons open it.
        Window("Recording", id: MacRecordView.windowID) {
            MacRecordView()
                .environment(appDelegate.store)
                .environment(appDelegate.navigation)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        Settings {
            MacSettingsView()
                .environment(appDelegate.store)
                .environment(appDelegate.library)
                .environment(appDelegate.navigation)
        }
        .defaultSize(width: 560, height: 720)
    }
}

/// Owns the app's state and its startup work, so the library is watched
/// (and a pending store load retried) whether or not a window is open.
@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    #if DEBUG
    // Must stay the first stored property: properties initialize in
    // declaration order, so this runs before Store() reads anything.
    private let updateTestGuard: Void = DebugLaunchOptions.refuseUpdateTestWithoutScratchPaths()
    #endif
    let store = Store()
    let library = LibraryIndex()
    let navigation = MacNavigation()
    let updater = MacUpdater()

    #if DEBUG
    func applicationWillFinishLaunching(_ notification: Notification) {
        DebugLaunchOptions.applyBeforeLaunch(store: store)
    }
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Update alerts and the post-update relaunch wait while busy.
        store.processing.onBusyChange = { [weak self] in self?.refreshUpdaterBusy() }
        navigation.onRecordingPersonChange = { [weak self] in self?.refreshUpdaterBusy() }
        refreshUpdaterBusy()
        // Writes store.json on first launch, so the location exists.
        store.save()
        // Finished sessions whose ~/Luxicon file is missing or failed to write.
        store.retryLibraryWrites()
        library.startWatching { [store] in Set(store.sessions.map(\.id)) }
        // A recording stopped by sleep is processed once the Mac is back.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.navigation.handleWake(store: self.store)
            }
        }
        Task {
            await library.reload(ownedIds: ownedIds)
            #if DEBUG
            DebugLaunchOptions.seedIfRequested(store: store)
            DebugLaunchOptions.retryFailedIfRequested(store: store)
            DebugLaunchOptions.deletePersonIfRequested(store: store)
            #endif
        }
    }

    /// Each time the app comes forward: retry a store.json read that failed
    /// at launch (until it succeeds, saves are refused so the library on disk
    /// is never replaced by blank state), then retry library writes that
    /// failed or whose files have gone missing since.
    func applicationDidBecomeActive(_ notification: Notification) {
        if store.loadPending {
            store.retryPendingLoad()
            if !store.loadPending {
                Task { await library.reload(ownedIds: ownedIds) }
            }
        }
        store.retryLibraryWrites()
    }

    /// Closing the main window doesn't quit: the app keeps watching
    /// ~/Luxicon (and a recording window can outlive it). The Dock icon,
    /// ⌘N, and ⌘F bring the window back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Quitting mid-recording asks first, in the recording window, with the
    /// same Save / Discard / Keep Recording question as closing it. Save
    /// finalizes the audio into a `.recorded` session before the app exits.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        #if DEBUG
        DebugRecording.log("applicationShouldTerminate: recordingActive=\(store.processing.recordingActive), "
            + "recording window \(navigation.recordingPerson == nil ? "closed" : "open")")
        #endif
        guard store.processing.recordingActive, navigation.recordingPerson != nil else {
            return .terminateNow
        }
        navigation.pendingQuit = true
        navigation.recordWindowRequest += 1
        return .terminateLater
    }

    private var ownedIds: Set<UUID> { Set(store.sessions.map(\.id)) }

    /// Busy: the recording window is open, audio is being captured, or a
    /// session is processing.
    private func refreshUpdaterBusy() {
        updater.setBusy(navigation.recordingPerson != nil || store.processing.recordingActive
            || !store.processing.bySession.isEmpty)
    }
}
