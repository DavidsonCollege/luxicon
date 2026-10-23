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
                        navigation: appDelegate.navigation)
        }

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
    let store = Store()
    let library = LibraryIndex()
    let navigation = MacNavigation()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Writes store.json on first launch, so the location exists.
        store.save()
        library.startWatching { [store] in Set(store.sessions.map(\.id)) }
        Task {
            await library.reload(ownedIds: ownedIds)
            #if DEBUG
            DebugSeed.runIfRequested(store: store)
            #endif
        }
    }

    /// A store.json read that failed at launch is retried each time the app
    /// comes forward; until it succeeds, saves are refused so the library on
    /// disk is never replaced by blank state.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard store.loadPending else { return }
        store.retryPendingLoad()
        if !store.loadPending {
            Task { await library.reload(ownedIds: ownedIds) }
        }
    }

    /// Closing the main window doesn't quit: the app keeps watching
    /// ~/Luxicon (and a recording window can outlive it). The Dock icon,
    /// ⌘N, and ⌘F bring the window back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private var ownedIds: Set<UUID> { Set(store.sessions.map(\.id)) }
}
