import SwiftUI

/// Root screen: your direct reports.
struct PeopleListView: View {
    @Environment(Store.self) private var store
    @State private var newPersonName = ""
    @State private var showingAddPerson = false
    @State private var path: [Route] = []

    var body: some View {
        @Bindable var coordinator = NavigationCoordinator.shared
        NavigationStack(path: $path) {
            Group {
                if store.people.isEmpty {
                    ContentUnavailableView {
                        Label("No people yet", systemImage: "person.2")
                    } description: {
                        Text("Add the people you hold 1-on-1s with. Everything is recorded, transcribed, and stored on this device only.")
                    } actions: {
                        Button("Add Person") { showingAddPerson = true }
                            .buttonStyle(.borderedProminent)
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
                                VStack(alignment: .leading) {
                                    Text(person.name).font(.headline)
                                    let count = store.sessions(for: person).count
                                    Text("^[\(count) session](inflect: true)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { indexSet in
                            for i in indexSet { store.deletePerson(store.people[i]) }
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
            // Siri / Action button: "Start a 1-on-1 with Josh" lands here.
            .fullScreenCover(item: $coordinator.recordPerson) { person in
                RecordSheetView(person: person)
            }
        }
    }

    enum Route: Hashable {
        case person(Person)
        case session(UUID)
        case myVoice
    }

    /// Programmatic navigation for screenshot automation and UI testing:
    /// launch with `-route person:<uuid>` / `session:<uuid>` / `myvoice`.
    private func handleRouteArgument() {
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
    }
}
