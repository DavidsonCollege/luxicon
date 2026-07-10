import SwiftUI
import LuxiconKit

/// Root screen: your direct reports.
struct PeopleListView: View {
    @Environment(Store.self) private var store
    @State private var newPersonName = ""
    @State private var showingAddPerson = false
    @State private var path: [Route] = []
    @State private var peopleFileURL: URL?
    @State private var importingPeople = false
    @State private var importResult: String?
    @State private var showingAboutGiving = false

    var body: some View {
        @Bindable var coordinator = NavigationCoordinator.shared
        NavigationStack(path: $path) {
            Group {
                if store.people.isEmpty {
                    VStack {
                        ContentUnavailableView {
                            Label("No people yet", systemImage: "person.2")
                        } description: {
                            Text("Add the people you hold 1-on-1s with. Everything is recorded, transcribed, and stored on this device only.")
                        } actions: {
                            Button("Add Person") { showingAddPerson = true }
                                .buttonStyle(.borderedProminent)
                        }
                        davidsonCredit
                            .padding(.bottom, 32)
                    }
                } else {
                    List {
                        if store.myVoiceEmbedding == nil {
                            NavigationLink(value: Route.myVoice) {
                                Label {
                                    VStack(alignment: .leading) {
                                        Text("Enroll your voice")
                                        Text("So transcripts label you automatically")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: "waveform.badge.mic")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        ForEach(store.people) { person in
                            NavigationLink(value: Route.person(person)) {
                                HStack(spacing: 12) {
                                    AvatarView(fileName: person.photoFileName, name: person.name)
                                    VStack(alignment: .leading) {
                                        Text(person.name).font(.headline)
                                        let count = store.sessions(for: person).count
                                        Text("^[\(count) session](inflect: true)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .onDelete { indexSet in
                            for i in indexSet { store.deletePerson(store.people[i]) }
                        }
                        Section {
                            davidsonCredit
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .padding(.top, 8)
                        }
                    }
                }
            }
            .navigationTitle("Luxicon")
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .person(let person): PersonDetailView(person: person)
                case .session(let id): SessionDetailView(sessionId: id)
                case .myVoice: MyVoiceView()
                }
            }
            .onAppear { handleRouteArgument() }
            .fileImporter(
                isPresented: $importingPeople,
                allowedContentTypes: [.json, .plainText, .text]
            ) { result in
                importPeople(result)
            }
            .alert("People Import", isPresented: Binding(
                get: { importResult != nil },
                set: { if !$0 { importResult = nil } }
            )) {
                Button("OK") { importResult = nil }
            } message: {
                Text(importResult ?? "")
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink(value: Route.myVoice) {
                        Image(systemName: store.myVoiceEmbedding == nil ? "person.crop.circle.badge.questionmark" : "person.crop.circle.badge.checkmark")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddPerson = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            importingPeople = true
                        } label: {
                            Label("Import People…", systemImage: "square.and.arrow.down")
                        }
                        // Menu content renders on open, so this refreshes the
                        // export file only when it might be shared — the roster
                        // (names + contexts) shouldn't sit in tmp rewritten on
                        // every keystroke of a context field.
                        .onAppear { writePeopleFile() }
                        if let peopleFileURL {
                            ShareLink(item: peopleFileURL) {
                                Label("Export People", systemImage: "square.and.arrow.up")
                            }
                        }
                        ShareLink(item: PeopleJSON.agentPrompt(existing: store.peopleForExport, me: store.meForExport)) {
                            Label("Share Agent Prompt", systemImage: "sparkles")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .alert("Add Person", isPresented: $showingAddPerson) {
                TextField("Name", text: $newPersonName)
                Button("Add") {
                    let name = newPersonName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        store.people.append(Person(name: name))
                        store.save()
                    }
                    newPersonName = ""
                }
                Button("Cancel", role: .cancel) { newPersonName = "" }
            } message: {
                Text("Who do you hold 1-on-1s with?")
            }
            .alert("Library Problem", isPresented: Binding(
                get: { store.startupWarning != nil || store.saveError != nil },
                set: { if !$0 { store.startupWarning = nil; store.saveError = nil } }
            )) {
                Button("OK") { store.startupWarning = nil; store.saveError = nil }
            } message: {
                Text(store.startupWarning ?? store.saveError ?? "")
            }
            // Siri / Action button: "Start a 1-on-1 with Josh" lands here.
            .fullScreenCover(item: $coordinator.recordPerson) { person in
                RecordSheetView(person: person)
            }
            // Control Center / Action button "Record 1-on-1" control.
            .sheet(isPresented: $coordinator.quickRecordPickerShown) {
                if let pending = pendingQuickRecordPerson {
                    pendingQuickRecordPerson = nil
                    coordinator.recordPerson = pending
                }
            } content: {
                QuickRecordPickerView { person in
                    // Presenting the cover mid-sheet-dismissal conflicts;
                    // hand off via onDismiss instead.
                    pendingQuickRecordPerson = person
                    coordinator.quickRecordPickerShown = false
                }
                .presentationDetents([.medium])
            }
            .sheet(isPresented: $showingAboutGiving) {
                AboutGivingView()
            }
            .onOpenURL { coordinator.handle(url: $0) }
        }
    }

    @State private var pendingQuickRecordPerson: Person?

    enum Route: Hashable {
        case person(Person)
        case session(UUID)
        case myVoice
    }

    /// Programmatic navigation for screenshot automation and UI testing:
    /// launch with `-route person:<uuid>` / `session:<uuid>` / `myvoice`.
    /// Debug builds only — no reason to ship a navigation backdoor, and
    /// screenshot runs use Debug configurations.
    private func handleRouteArgument() {
        #if !DEBUG
        return
        #else
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-route"), args.indices.contains(i + 1) else { return }
        let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first {
        case "myvoice":
            path = [.myVoice]
        case "person":
            if let id = parts.last.flatMap(UUID.init(uuidString:)),
               let person = store.person(id: id) {
                path = [.person(person)]
            }
        case "session":
            if let id = parts.last.flatMap(UUID.init(uuidString:)),
               let session = store.sessions.first(where: { $0.id == id }),
               let person = store.person(id: session.personId) {
                path = [.person(person), .session(session.id)]
            }
        case "record":
            if let id = parts.last.flatMap(UUID.init(uuidString:)),
               let person = store.person(id: id) {
                NavigationCoordinator.shared.recordPerson = person
            }
        default:
            break
        }
        #endif
    }

    /// Credit line that opens the giving screen — shown at the bottom of the
    /// roster and under the empty state, so the Davidson framing is on the
    /// home screen in both cases.
    private var davidsonCredit: some View {
        Button {
            showingAboutGiving = true
        } label: {
            VStack(spacing: 2) {
                Image(decorative: "AppIconLarge")
                    .resizable()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.bottom, 4)
                Text("A free, open-source service of Davidson College")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Learn more & give ›")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color("DavidsonRed"))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    /// ShareLink needs a file URL ready before the tap.
    private func writePeopleFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Luxicon People.json")
        if let data = try? PeopleJSON.template(existing: store.peopleForExport, me: store.meForExport) {
            try? data.write(to: url)
            peopleFileURL = url
        }
    }

    private func importPeople(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let file = try PeopleJSON.parse(Data(contentsOf: url))
            let (added, updated) = store.importPeople(file)
            importResult = "Added \(added), updated \(updated). Nobody is removed by imports."
        } catch {
            importResult = "Import failed: \(error.localizedDescription)"
        }
    }
}
