import SwiftUI
import LuxiconKit

/// One row in the content column: a Mac session, or a library file.
struct SessionItem: Identifiable {
    enum Kind {
        case mac(SessionRecord)
        /// `orphan`: a Mac-recorded file with no store record.
        case library(TranscriptLibrary.Session, orphan: Bool)
    }

    let kind: Kind
    let personName: String

    var id: SessionRef {
        switch kind {
        case .mac(let record): .mac(record.id)
        case .library(let session, _): .library(sourceFile: session.libraryKey)
        }
    }

    var date: Date {
        switch kind {
        case .mac(let record): record.date
        case .library(let session, _): session.transcript.date
        }
    }

    /// Mac sessions, and orphaned Mac files (file only). Phone sessions
    /// are read-only.
    var isDeletable: Bool {
        switch kind {
        case .mac: true
        case .library(_, let orphan): orphan
        }
    }

    /// For search: the transcript as a one-session library entry.
    var librarySession: TranscriptLibrary.Session? {
        switch kind {
        case .mac(let record):
            guard let transcript = record.transcript else { return nil }
            return TranscriptLibrary.Session(
                person: personName, transcript: transcript, summary: record.summary,
                sourceFile: record.libraryFileName ?? "", sessionId: record.id,
                source: TranscriptExport.macSource)
        case .library(let session, _):
            return session
        }
    }
}

/// Lists and lookups across the store and the library index.
@MainActor
enum SessionCatalog {
    /// Sessions for a sidebar selection, newest first. A person's list
    /// merges their Mac sessions with library sessions under the same name.
    static func items(for sidebar: SidebarItem?, store: Store, library: LibraryIndex) -> [SessionItem] {
        var items: [SessionItem] = []
        func macItems(_ records: [SessionRecord]) -> [SessionItem] {
            records.map { SessionItem(kind: .mac($0), personName: store.person(id: $0.personId)?.name ?? "Unknown") }
        }
        func libraryItems(named name: String?) -> [SessionItem] {
            let matches: (TranscriptLibrary.Session) -> Bool = { session in
                guard let name else { return true }
                return session.person.localizedCaseInsensitiveCompare(name) == .orderedSame
            }
            return library.phoneSessions.filter(matches).map {
                SessionItem(kind: .library($0, orphan: false), personName: $0.person)
            } + library.orphanMacSessions.filter(matches).map {
                SessionItem(kind: .library($0, orphan: true), personName: $0.person)
            }
        }
        switch sidebar {
        case .allSessions:
            items = macItems(store.sessions) + libraryItems(named: nil)
        case .person(let id):
            guard let person = store.person(id: id) else { return [] }
            items = macItems(store.sessions(for: person)) + libraryItems(named: person.name)
        case .libraryPerson(let name):
            items = libraryItems(named: name)
        case .vocabulary, .none:
            return []
        }
        return items.sorted { $0.date > $1.date }
    }

    /// Look up a library session by its `libraryKey`.
    static func librarySession(_ key: String, library: LibraryIndex) -> TranscriptLibrary.Session? {
        library.phoneSessions.first { $0.libraryKey == key }
            ?? library.orphanMacSessions.first { $0.libraryKey == key }
    }

    private static func content(_ ref: SessionRef?, store: Store, library: LibraryIndex)
        -> (transcript: MeetingTranscript, summary: SessionSummary?)? {
        switch ref {
        case .mac(let id):
            guard let record = store.sessions.first(where: { $0.id == id }),
                  let transcript = record.transcript else { return nil }
            return (transcript, record.summary)
        case .library(let file):
            guard let session = librarySession(file, library: library) else { return nil }
            return (session.transcript, session.summary)
        case .none:
            return nil
        }
    }

    static func transcriptMarkdown(_ ref: SessionRef?, store: Store, library: LibraryIndex) -> String? {
        content(ref, store: store, library: library).map { TranscriptExport.markdown($0.transcript) }
    }

    static func summaryMarkdown(_ ref: SessionRef?, store: Store, library: LibraryIndex) -> String? {
        guard let content = content(ref, store: store, library: library),
              let summary = content.summary else { return nil }
        return TranscriptExport.summaryMarkdown(summary, transcript: content.transcript)
    }

    /// First line of a summary for list rows, without markdown emphasis.
    static func summaryFirstLine(_ summary: SessionSummary?) -> String? {
        guard let summary else { return nil }
        for block in MeetingSummarizer.overviewBlocks(summary.overview) {
            let text: String
            switch block {
            case .paragraph(let t): text = t
            case .bullet(_, let t): text = t
            }
            let plain = text.replacingOccurrences(of: "**", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !plain.isEmpty { return plain }
        }
        return nil
    }
}

/// Content column: the selected person's (or everyone's) sessions.
struct SessionListView: View {
    @Environment(Store.self) private var store
    @Environment(LibraryIndex.self) private var library
    @Environment(MacNavigation.self) private var navigation
    @FocusState private var searchFocused: Bool
    @State private var pendingDelete: SessionItem?
    @State private var editingContext = false

    private struct SearchResult {
        let item: SessionItem
        let hits: [TranscriptLibrary.SearchHit]
    }

    var body: some View {
        @Bindable var navigation = navigation
        let items = SessionCatalog.items(for: navigation.sidebar, store: store, library: library)
        let query = navigation.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let results = query.isEmpty ? [] : search(query, in: items)
        VStack(spacing: 0) {
            header(count: items.count)
            List(selection: $navigation.session) {
                if query.isEmpty {
                    ForEach(items) { item in
                        row(item).tag(item.id)
                    }
                } else {
                    ForEach(results, id: \.item.id) { result in
                        searchRow(result).tag(result.item.id)
                    }
                }
            }
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView("No Sessions", systemImage: "waveform",
                                           description: Text(emptyDescription))
                } else if !query.isEmpty, results.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .contextMenu(forSelectionType: SessionRef.self) { refs in
                if let ref = refs.first, let item = items.first(where: { $0.id == ref }) {
                    contextMenu(for: item)
                }
            }
            .onDeleteCommand {
                if let item = items.first(where: { $0.id == navigation.session }), item.isDeletable {
                    pendingDelete = item
                }
            }
        }
        .navigationTitle(title)
        .searchable(text: $navigation.searchText, placement: .toolbar, prompt: "Search transcripts")
        .searchFocused($searchFocused)
        .onChange(of: navigation.searchFocusRequest) { searchFocused = true }
        .confirmationDialog(
            "Delete this session?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { item in
            Button("Delete", role: .destructive) { delete(item) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This also removes it from ~/Luxicon, so Claude (MCP) will no longer see it.")
        }
        .sheet(isPresented: $editingContext) {
            if case .person(let id) = navigation.sidebar, let person = store.person(id: id) {
                ContextSheet(person: person)
            }
        }
    }

    // MARK: - Header

    private var title: String {
        switch navigation.sidebar {
        case .person(let id): store.person(id: id)?.name ?? "Sessions"
        case .libraryPerson(let name): name
        default: "All Sessions"
        }
    }

    private var emptyDescription: String {
        switch navigation.sidebar {
        case .person(let id):
            "Recordings with \(store.person(id: id)?.name ?? "this person") will appear here."
        default:
            "Recordings made here, and 1-on-1s your iPhone sends to ~/Luxicon, appear here."
        }
    }

    @ViewBuilder
    private func header(count: Int) -> some View {
        switch navigation.sidebar {
        case .person(let id):
            if let person = store.person(id: id) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        AvatarPicker(fileName: person.photoFileName, name: person.name, size: 44) { data in
                            store.setPhoto(data, for: person.id)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(person.name).font(.title3.weight(.semibold))
                            Text("^[\(count) session](inflect: true)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            navigation.requestRecording(with: person)
                        } label: {
                            Label("Record", systemImage: "record.circle")
                        }
                        .help("New recording with \(person.name)")
                    }
                    // Personal context belongs to the opt-in AI summaries.
                    if store.aiSummariesEnabled {
                        Button {
                            editingContext = true
                        } label: {
                            Text(person.context?.isEmpty == false ? person.context! : "Add context: role, projects, current threads…")
                                .font(.callout)
                                .foregroundStyle(person.context?.isEmpty == false ? .primary : .secondary)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Context the summarizer uses for \(person.name)")
                    }
                }
                .padding(12)
                Divider()
            }
        case .libraryPerson(let name):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    AvatarView(fileName: nil, name: name, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.title3.weight(.semibold))
                        Text("^[\(count) session](inflect: true) from iPhone")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Add to People") {
                        let person = Person(name: name)
                        store.people.append(person)
                        store.save()
                        navigation.sidebar = .person(person.id)
                    }
                    .help("Add \(name) to your people so you can record with them on this Mac")
                }
            }
            .padding(12)
            Divider()
        default:
            EmptyView()
        }
    }

    // MARK: - Rows

    private func row(_ item: SessionItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            SourceBadge(kind: item.kind)
            switch item.kind {
            case .mac(let record):
                VStack(alignment: .leading, spacing: 2) {
                    if showsPersonName { Text(item.personName).font(.headline) }
                    SessionRow(session: record)
                    if record.listLabel == nil, let line = SessionCatalog.summaryFirstLine(record.summary) {
                        Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            case .library(let session, _):
                VStack(alignment: .leading, spacing: 2) {
                    if showsPersonName { Text(item.personName).font(.headline) }
                    Text(session.transcript.date.formatted(date: .abbreviated, time: .shortened))
                    if let line = SessionCatalog.summaryFirstLine(session.summary) {
                        Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(TranscriptExport.timestamp(session.transcript.duration))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func searchRow(_ result: SearchResult) -> some View {
        HStack(alignment: .top, spacing: 8) {
            SourceBadge(kind: result.item.kind)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(result.item.personName).font(.headline)
                    Spacer()
                    Text(result.item.date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(result.hits.prefix(2).enumerated()), id: \.offset) { _, hit in
                    Text("\(Text(hit.turn.displayName).fontWeight(.semibold)): \(hit.turn.text)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if result.hits.count > 2 {
                    Text("+\(result.hits.count - 2) more")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// Everyone's list mixes people, so name each row.
    private var showsPersonName: Bool {
        navigation.sidebar == .allSessions
    }

    @ViewBuilder
    private func contextMenu(for item: SessionItem) -> some View {
        Button("Copy Transcript") {
            if let text = SessionCatalog.transcriptMarkdown(item.id, store: store, library: library) {
                Pasteboard.copy(text)
            }
        }
        .disabled(SessionCatalog.transcriptMarkdown(item.id, store: store, library: library) == nil)
        Button("Copy Summary") {
            if let text = SessionCatalog.summaryMarkdown(item.id, store: store, library: library) {
                Pasteboard.copy(text)
            }
        }
        .disabled(SessionCatalog.summaryMarkdown(item.id, store: store, library: library) == nil)
        if item.isDeletable {
            Divider()
            Button("Delete…", role: .destructive) { pendingDelete = item }
        }
    }

    // MARK: - Search and delete

    /// Search each session's transcript with `TranscriptLibrary.search`,
    /// keeping sessions with at least one hit.
    private func search(_ query: String, in items: [SessionItem]) -> [SearchResult] {
        items.compactMap { item in
            guard let session = item.librarySession else { return nil }
            var one = TranscriptLibrary()
            one.sessions = [session]
            let hits = one.search(query, limit: 50)
            return hits.isEmpty ? nil : SearchResult(item: item, hits: hits)
        }
    }

    private func delete(_ item: SessionItem) {
        if navigation.session == item.id { navigation.session = nil }
        switch item.kind {
        case .mac(let record):
            store.deleteSession(record)
        case .library(let session, let orphan):
            guard orphan else { return }
            store.deleteOrphanLibraryFile(session)
            Task { await library.reload(ownedIds: Set(store.sessions.map(\.id))) }
        }
    }
}

/// Mac or iPhone, by where the session was recorded.
struct SourceBadge: View {
    let kind: SessionItem.Kind

    var body: some View {
        let isMac: Bool = {
            switch kind {
            case .mac: return true
            case .library(_, let orphan): return orphan
            }
        }()
        Image(systemName: isMac ? "laptopcomputer" : "iphone")
            .foregroundStyle(.secondary)
            .frame(width: 18)
            .padding(.top, 2)
            .accessibilityLabel(isMac ? "Mac" : "iPhone")
            .help(isMac ? "Recorded on this Mac" : "From iPhone (read-only)")
    }
}

/// A person's summarizer context, edited in a sheet.
private struct ContextSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let person: Person

    var body: some View {
        NavigationStack {
            ContextDetailView(
                title: "Context for \(person.name)",
                text: Binding(
                    get: { store.person(id: person.id)?.context ?? "" },
                    set: { newValue in
                        guard let i = store.people.firstIndex(where: { $0.id == person.id }) else { return }
                        store.people[i].context = newValue.isEmpty ? nil : newValue
                    }
                ),
                syncedExplanation: store.peopleSyncConfigured
                    ? "People sync is on: \(person.name)'s context comes from the synced file and can't be edited here — edit the file instead."
                    : nil,
                editingExplanation: "Background the summarizer uses to interpret your 1-on-1s — e.g. “Senior sysadmin; runs the identity platform; discussing promotion this quarter.” Stays on this Mac unless you configure people sync — then the synced file's context wins.",
                emptyPrompt: store.peopleSyncConfigured
                    ? "No context yet — add \(person.name) to the synced people file."
                    : "Role, projects, current threads…",
                onSave: { store.save() }
            )
            .formStyle(.grouped)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(width: 480, height: 360)
    }
}
