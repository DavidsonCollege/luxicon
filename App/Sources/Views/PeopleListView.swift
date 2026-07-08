import SwiftUI

/// Root screen: your direct reports.
struct PeopleListView: View {
    @Environment(Store.self) private var store
    @State private var newPersonName = ""
    @State private var showingAddPerson = false

    var body: some View {
        NavigationStack {
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
            .navigationTitle("Sitdown")
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .person(let person): PersonDetailView(person: person)
                case .myVoice: MyVoiceView()
                }
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
        }
    }

    enum Route: Hashable {
        case person(Person)
        case myVoice
    }
}
