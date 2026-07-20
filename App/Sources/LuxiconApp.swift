import SwiftUI

@main
struct LuxiconApp: App {
    @State private var store = Store()
    // The -route check keeps first-launch onboarding from blocking debug
    // screenshot automation (see PeopleListView.handleRouteArgument).
    @State private var showOnboarding =
        !UserDefaults.standard.bool(forKey: OnboardingView.seenKey)
        && !ProcessInfo.processInfo.arguments.contains("-route")
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            PeopleListView()
                .environment(store)
                .fullScreenCover(isPresented: $showOnboarding) {
                    OnboardingView()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // GPU inference in a backgrounded app is killed by iOS; cancel
            // processing cleanly and resume when we're frontmost again.
            switch phase {
            case .background:
                store.handleScenePhaseChange(toBackground: true)
                // Persist in-memory edits (e.g. context fields save on view
                // disappear) before iOS gets a chance to jetsam the process.
                store.save()
            case .active:
                // A load deferred by a locked-device launch retries here as
                // well as on the unlock notification (ordering isn't
                // guaranteed, and .active implies the data is readable).
                store.retryPendingLoad()
                store.handleScenePhaseChange(toBackground: false)
                store.syncVocabularyIfConfigured()
                store.syncPeopleIfConfigured()
                store.retryFailedPushesIfEnabled()
            default:
                break
            }
        }
    }
}
