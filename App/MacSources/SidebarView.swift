import SwiftUI
import LuxiconKit

/// Sidebar: record button, fixed entries, then people (the Mac's own,
/// followed by names that only appear on phone-pushed sessions).
struct SidebarView: View {
    @Environment(Store.self) private var store
    @Environment(LibraryIndex.self) private var library
    @Environment(MacNavigation.self) private var navigation
    @State private var renaming: Person?
    @State private var renameText = ""
    @State private var addingPerson = false
    @State private var newPersonName = ""

    var body: some View {
        @Bindable var navigation = navigation
        List(selection: $navigation.sidebar) {
            Section {
                Label("All Sessions", systemImage: "tray.full")
                    .tag(SidebarItem.allSessions)
                Label("Vocabulary", systemImage: "character.book.closed")
                    .tag(SidebarItem.vocabulary)
            }
            Section("People") {
                ForEach(store.people) { person in
                    PersonSidebarRow(
                        name: person.name, photoFileName: person.photoFileName,
                        items: SessionCatalog.items(for: .person(person.id), store: store, library: library))
                    .tag(SidebarItem.person(person.id))
                    .contextMenu {
                        Button("New Recording…") { navigation.requestRecording(with: person) }
                        Button("Rename…") {
                            renameText = person.name
                            renaming = person
                        }
                    }
                }
                ForEach(library.libraryOnlyPeople(known: store.people), id: \.self) { name in
                    PersonSidebarRow(
                        name: name, photoFileName: nil,
                        items: SessionCatalog.items(for: .libraryPerson(name), store: store, library: library),
                        fromPhoneOnly: true)
                    .tag(SidebarItem.libraryPerson(name))
                }
            }
        }
        .safeAreaInset(edge: .top) {
            Button {
                navigation.beginNewRecording(store: store)
            } label: {
                Label("New Recording", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .help("Record a 1-on-1 (⌘N)")
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    addingPerson = true
                } label: {
                    Label("Add Person", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            .padding(10)
        }
        .alert("Rename Person", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let renaming { store.renamePerson(id: renaming.id, to: renameText) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Finished sessions in ~/Luxicon are renamed to match.")
        }
        .alert("Add Person", isPresented: $addingPerson) {
            TextField("Name", text: $newPersonName)
            Button("Add") {
                let name = newPersonName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    let person = Person(name: name)
                    store.people.append(person)
                    store.save()
                    navigation.sidebar = .person(person.id)
                }
                newPersonName = ""
            }
            Button("Cancel", role: .cancel) { newPersonName = "" }
        } message: {
            Text("Who do you hold 1-on-1s with?")
        }
    }
}

/// Avatar, name, session count, and the most recent session's date.
private struct PersonSidebarRow: View {
    let name: String
    let photoFileName: String?
    let items: [SessionItem]
    var fromPhoneOnly = false

    var body: some View {
        HStack(spacing: 8) {
            AvatarView(fileName: photoFileName, name: name, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .help(fromPhoneOnly ? "\(name) appears only in sessions from your iPhone" : name)
    }

    private var detail: String {
        let count = items.count == 1 ? "1 session" : "\(items.count) sessions"
        // items are newest first.
        guard let last = items.first?.date else { return fromPhoneOnly ? "iPhone · \(count)" : count }
        let date = last.formatted(date: .abbreviated, time: .omitted)
        return fromPhoneOnly ? "iPhone · \(count) · \(date)" : "\(count) · \(date)"
    }
}
