import AppKit
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
    /// `sourceFile` carries the session's `libraryKey` (relative path, plus
    /// `#n` inside a bundle), which is unique; a bare file name is not.
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
    /// Who the recording in the "Recording" window is with; nil when none
    /// is in progress. Set it through `requestRecording(with:)`.
    var recordingPerson: Person?
    /// Identifies the current recording request, so each new recording
    /// starts from fresh window state.
    var recordingID = UUID()
    /// Bumped to bring the recording window forward (the main window
    /// observes it and calls `openWindow`).
    var recordWindowRequest = 0
    /// Sessions saved because the Mac went to sleep mid-recording; they're
    /// processed on wake, when the main window explains what happened.
    var sleepStoppedSessions: [UUID] = []
    var showingSleepStopAlert = false
    /// ⌘Q arrived mid-recording; the app is waiting (`.terminateLater`)
    /// for the recording window's Save / Discard / Keep Recording answer.
    var pendingQuit = false

    /// Answer a held quit: go ahead, or stay open. No-op when none is held.
    func resolvePendingQuit(quit: Bool) {
        guard pendingQuit else { return }
        pendingQuit = false
        NSApp.reply(toApplicationShouldTerminate: quit)
    }
    var searchText = ""
    /// New Recording with no person selected asks who it's with first.
    var showingRecordingPicker = false
    /// Bumped by Find (⌘F); the session list focuses its search field.
    var searchFocusRequest = 0

    /// ⌘N and the sidebar's record button: record with the selected person,
    /// or ask who the meeting is with.
    func beginNewRecording(store: Store) {
        if recordingPerson != nil {
            // One recording at a time: show the one in progress.
            recordWindowRequest += 1
        } else if case .person(let id) = sidebar, let person = store.person(id: id) {
            requestRecording(with: person)
        } else {
            showingRecordingPicker = true
        }
    }

    /// Start a recording with `person` and open its window. While one is
    /// already in progress, this only brings that window forward.
    func requestRecording(with person: Person) {
        if recordingPerson == nil {
            recordingPerson = person
            recordingID = UUID()
        }
        recordWindowRequest += 1
    }

    /// The Mac woke: process what sleep interrupted, and say why the
    /// recording stopped.
    func handleWake(store: Store) {
        guard !sleepStoppedSessions.isEmpty else { return }
        for id in sleepStoppedSessions {
            if let session = store.sessions.first(where: { $0.id == id }), session.status == .recorded {
                #if DEBUG
                DebugRecording.log("wake: processing \(id) (was .recorded)")
                #endif
                store.startProcessing(session)
            }
        }
        sleepStoppedSessions = []
        showingSleepStopAlert = true
    }
}

extension View {
    /// A comfortable text column (about 70 characters, at most 760 pt)
    /// instead of spanning a wide window. Apply it to a List, and
    /// `readingRow()` to its rows and section headers: the List keeps the
    /// full column width, so scrolling, the background, and the scroll bar
    /// reach the column's edges, while each row's content is inset to the
    /// centered reading column.
    func readingWidth() -> some View {
        modifier(ReadingWidth())
    }
}

private struct ReadingWidth: ViewModifier {
    static let maxWidth: CGFloat = 760
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .environment(\.readingInset, max(0, (width - Self.maxWidth) / 2))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// Main window: people → sessions → session detail.
struct MacRootView: View {
    @Environment(Store.self) private var store
    @Environment(LibraryIndex.self) private var library
    @Environment(MacNavigation.self) private var navigation
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var showingOnboarding = MacOnboardingView.shouldShow

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
        .sheet(isPresented: $showingOnboarding) {
            MacOnboardingView()
        }
        .sheet(isPresented: $navigation.showingRecordingPicker) {
            RecordingPersonPicker()
        }
        .onChange(of: navigation.recordWindowRequest) {
            openWindow(id: MacRecordView.windowID)
        }
        .background {
            // Its own host, so it doesn't collide with the library alert.
            Color.clear
                .alert("Recording stopped because the Mac went to sleep.",
                       isPresented: $navigation.showingSleepStopAlert) {
                    Button("OK") {}
                } message: {
                    Text("The audio up to that point was saved.")
                }
        }
        #if DEBUG
        .onChange(of: navigation.showingSleepStopAlert) { _, showing in
            if showing { DebugRecording.log("main window: sleep-stop alert shown") }
        }
        .task { DebugRecording.requestRecordingIfAsked(store: store, navigation: navigation) }
        .task {
            if DebugLaunchOptions.has("-openSettings") { openSettings() }
            DebugLaunchOptions.applyRoute(store: store, navigation: navigation, openSettings: openSettings,
                                          showOnboarding: { showingOnboarding = true })
        }
        #endif
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
        case .library(let key):
            if let session = SessionCatalog.librarySession(key, library: library) {
                LibrarySessionDetailView(session: session)
                    .id(key)
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
        navigation.requestRecording(with: person)
        dismiss()
    }
}
