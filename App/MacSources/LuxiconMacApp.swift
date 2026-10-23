import SwiftUI

/// Mac entry point. A placeholder window until the desktop UI lands; the
/// save on appear writes store.json so the Application Support location is
/// exercised from first launch.
@main
struct LuxiconMacApp: App {
    @State private var store = Store()
    @State private var library = LibraryIndex()

    var body: some Scene {
        WindowGroup {
            Text("Luxicon")
                .frame(minWidth: 480, minHeight: 320)
                .environment(store)
                .environment(library)
                .onAppear { store.save() }
                .task {
                    library.startWatching { [store] in Set(store.sessions.map(\.id)) }
                    await library.reload(ownedIds: Set(store.sessions.map(\.id)))
                    #if DEBUG
                    DebugSeed.runIfRequested(store: store)
                    #endif
                }
        }
    }
}
