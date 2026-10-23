import SwiftUI

/// Settings scene (⌘,): the phone's My Voice screen, which holds every
/// setting, with the phone's Mac-sync section swapped for the Mac's.
struct MacSettingsView: View {
    var body: some View {
        NavigationStack {
            MyVoiceView()
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 640, idealHeight: 720)
    }
}

/// Placeholder for the Mac's iPhone-sync settings; Task 8 fills it in.
struct MacSyncSettingsSection: View {
    var body: some View {
        Section("iPhone sync") {}
    }
}
