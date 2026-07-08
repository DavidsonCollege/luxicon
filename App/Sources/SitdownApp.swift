import SwiftUI

@main
struct SitdownApp: App {
    @State private var store = Store()

    var body: some Scene {
        WindowGroup {
            PeopleListView()
                .environment(store)
        }
    }
}
