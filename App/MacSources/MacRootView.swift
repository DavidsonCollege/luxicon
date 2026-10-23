import SwiftUI
import LuxiconKit

/// What the sidebar can select.
enum SidebarItem: Hashable {
    case allSessions
    /// A person in the Mac's own list.
    case person(UUID)
    /// A name that only appears on phone-pushed sessions in ~/Luxicon.
    case libraryPerson(String)
    case vocabulary
}

/// A session in the content column: one the Mac owns (store.json), or a
/// file in ~/Luxicon (phone push, or a Mac file whose record is gone).
enum SessionRef: Hashable {
    case mac(UUID)
    case library(sourceFile: String)
}

/// Window-wide navigation state. One main window, so one instance, shared
/// by the views, the menu commands, and (later) the recording window.
@Observable @MainActor
final class MacNavigation {
    var sidebar: SidebarItem? = .allSessions {
        didSet { if oldValue != sidebar { session = nil } }
    }
    var session: SessionRef?
    /// Set to start a recording with this person (the recording window
    /// reacts to it).
    var recordingPerson: Person?
    var searchText = ""
    /// New Recording with no person selected asks who it's with first.
    var showingRecordingPicker = false
    /// Bumped by Find (⌘F); the session list focuses its search field.
    var searchFocusRequest = 0

    /// ⌘N and the sidebar's record button: record with the selected person,
    /// or ask who the meeting is with.
    func beginNewRecording(store: Store) {
        if case .person(let id) = sidebar, let person = store.person(id: id) {
            recordingPerson = person
        } else {
            showingRecordingPicker = true
        }
    }
}

extension View {
    /// A comfortable text column (about 70 characters) instead of spanning
    /// a wide window.
    func readingWidth() -> some View {
        frame(maxWidth: 760).frame(maxWidth: .infinity)
    }
}

/// Main window: people → sessions → session detail.
struct MacRootView: View {
    @Environment(Store.self) private var store
    @Environment(LibraryIndex.self) private var library
    @Environment(MacNavigation.self) private var navigation

    var body: some View {
        @Bindable var navigation = navigation
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } content: {
            contentColumn
                .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        } detail: {
            detailColumn
        }
        .frame(minWidth: 900, minHeight: 600)
        // ⌘C with a session selected (and no text field focused) copies its
        // transcript; text fields keep their own Copy.
        .onCopyCommand {
            guard let markdown = SessionCatalog.transcriptMarkdown(
                navigation.session, store: store, library: library) else { return [] }
            return [NSItemProvider(object: markdown as NSString)]
        }
        .sheet(isPresented: $navigation.showingRecordingPicker) {
            RecordingPersonPicker()
        }
        .alert("Library Problem", isPresented: Binding(
            get: { store.startupWarning != nil || store.saveError != nil },
            set: { if !$0 { store.startupWarning = nil; store.saveError = nil } }
        )) {
            Button("OK") { store.startupWarning = nil; store.saveError = nil }
        } message: {
            Text(store.startupWarning ?? store.saveError ?? "")
        }
    }

    @ViewBuilder
    private var contentColumn: some View {
        switch navigation.sidebar {
        case .vocabulary:
            VocabularyListView()
        case .none:
            ContentUnavailableView("Nothing Selected", systemImage: "sidebar.left")
        default:
            SessionListView()
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        switch navigation.session {
        case .mac(let id):
            SessionDetailView(sessionId: id)
                .id(id)
        case .library(let sourceFile):
            if let session = SessionCatalog.librarySession(sourceFile, library: library) {
                LibrarySessionDetailView(session: session)
                    .id(sourceFile)
            } else {
                ContentUnavailableView("Session Not Found", systemImage: "doc.questionmark",
                                       description: Text("It is no longer in ~/Luxicon."))
            }
        case .none:
            ContentUnavailableView("No Session Selected", systemImage: "text.bubble")
        }
    }
}

/// Who a new recording is with, when no person is selected.
struct RecordingPersonPicker: View {
    @Environment(Store.self) private var store
    @Environment(MacNavigation.self) private var navigation
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Recording").font(.headline)
            Text("Who is this 1-on-1 with?")
                .foregroundStyle(.secondary)
            List(store.people, selection: $selection) { person in
                HStack(spacing: 8) {
                    AvatarView(fileName: person.photoFileName, name: person.name, size: 24)
                    Text(person.name)
                }
                .tag(person.id)
            }
            .frame(minHeight: 180)
            .contextMenu(forSelectionType: UUID.self) { _ in } primaryAction: { ids in
                if let id = ids.first { start(id) }
            }
            HStack {
                TextField("Someone new", text: $newName)
                    .onSubmit(addPerson)
                Button("Add", action: addPerson)
                    .disabled(trimmedName.isEmpty)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start Recording") { if let selection { start(selection) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
        }
        .padding(20)
        .frame(width: 380, height: 420)
    }

    private var trimmedName: String {
        newName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addPerson() {
        guard !trimmedName.isEmpty else { return }
        let person = Person(name: trimmedName)
        store.people.append(person)
        store.save()
        newName = ""
        selection = person.id
    }

    private func start(_ id: UUID) {
        guard let person = store.person(id: id) else { return }
        navigation.recordingPerson = person
        dismiss()
    }
}
