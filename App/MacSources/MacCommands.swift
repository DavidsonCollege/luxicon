import SwiftUI
import LuxiconKit

/// Menu bar commands for the main window. ⌘C (copy the selected session's
/// transcript) is the root view's `onCopyCommand`, so Edit → Copy keeps
/// working in text fields; ⌘⇧C copies the summary from here.
struct MacCommands: Commands {
    let store: Store
    let library: LibraryIndex
    let navigation: MacNavigation
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Recording…") {
                // The person picker is a sheet on the main window.
                openWindow(id: LuxiconMacApp.mainWindowID)
                navigation.beginNewRecording(store: store)
            }
            .keyboardShortcut("n")
        }
        CommandGroup(after: .pasteboard) {
            Section {
                Button("Copy Transcript") {
                    if let text = SessionCatalog.transcriptMarkdown(navigation.session, store: store, library: library) {
                        Pasteboard.copy(text)
                    }
                }
                .disabled(SessionCatalog.transcriptMarkdown(navigation.session, store: store, library: library) == nil)
                Button("Copy Summary") {
                    if let text = SessionCatalog.summaryMarkdown(navigation.session, store: store, library: library) {
                        Pasteboard.copy(text)
                    }
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(SessionCatalog.summaryMarkdown(navigation.session, store: store, library: library) == nil)
            }
        }
        CommandGroup(after: .textEditing) {
            Button("Find Sessions…") {
                openWindow(id: LuxiconMacApp.mainWindowID)
                if navigation.sidebar == nil || navigation.sidebar == .vocabulary {
                    navigation.sidebar = .allSessions
                }
                navigation.searchFocusRequest += 1
            }
            .keyboardShortcut("f")
        }
    }
}
