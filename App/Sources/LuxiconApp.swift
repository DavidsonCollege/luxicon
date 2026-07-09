import SwiftUI

@main
struct LuxiconApp: App {
    @State private var store = Store()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            PeopleListView()
                .environment(store)
        }
        .onChange(of: scenePhase) { _, phase in
            // GPU inference in a backgrounded app is killed by iOS; cancel
            // processing cleanly and resume when we're frontmost again.
            switch phase {
            case .background:
                store.handleScenePhaseChange(toBackground: true)
            case .active:
                store.handleScenePhaseChange(toBackground: false)
                store.syncVocabularyIfConfigured()
                store.retryFailedPushesIfEnabled()
            default:
                break
            }
        }
    }
}
