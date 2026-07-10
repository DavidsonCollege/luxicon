import SwiftUI
import LuxiconKit

/// The full vocabulary list with add/import/export, pushed from My Voice —
/// the list can run to hundreds of terms, too long to live inline there.
struct VocabularyListView: View {
    @Environment(Store.self) private var store

    @State private var newTerm = ""
    @State private var vocabularyFileURL: URL?
    @State private var importingVocabulary = false
    @State private var importResult: String?

    var body: some View {
        Form {
            // While URL sync is on, the remote file is the source of truth
            // and would silently overwrite local edits on the next sync —
            // adding, importing, and deleting are disabled to match.
            Section {
                if !store.vocabularySyncConfigured {
                    HStack {
                        TextField("Add a name or term", text: $newTerm)
                            .onSubmit { addTerm() }
                        Button("Add") { addTerm() }
                            .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if let vocabularyFileURL {
                    ShareLink(item: vocabularyFileURL) {
                        Label("Export Vocabulary Template", systemImage: "square.and.arrow.up")
                    }
                }
                if !store.vocabularySyncConfigured {
                    Button {
                        importingVocabulary = true
                    } label: {
                        Label("Import Vocabulary…", systemImage: "square.and.arrow.down")
                    }
                }
                ShareLink(item: VocabularyJSON.agentPrompt(existing: store.vocabularyEntries)) {
                    Label("Share Agent Prompt", systemImage: "sparkles")
                }
            } footer: {
                Text(store.vocabularySyncConfigured
                    ? "Project names, acronyms, jargon — words transcription tends to get wrong. Your name and your people's names are included automatically. This list is synchronized from a URL (set in My Voice) and read-only here — edit the file it points at."
                    : "Project names, acronyms, jargon — words transcription tends to get wrong. Your name and your people's names are included automatically. Export the JSON template, have a person or AI assistant fill in terms and common mishearings, then import it back.")
            }

            Section {
                ForEach(store.vocabularyEntries, id: \.term) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.term)
                        if !entry.soundsLike.isEmpty {
                            Text("sounds like: \(entry.soundsLike.joined(separator: ", "))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    store.vocabularyEntries.remove(atOffsets: offsets)
                    store.save()
                }
                .deleteDisabled(store.vocabularySyncConfigured)
            } header: {
                Text("\(store.vocabularyEntries.count) terms")
            }
        }
        .navigationTitle("Vocabulary")
        .onAppear { writeVocabularyFile() }
        .onChange(of: store.vocabularyEntries) { writeVocabularyFile() }
        .onDisappear { store.save() }
        .fileImporter(
            isPresented: $importingVocabulary,
            allowedContentTypes: [.json, .plainText, .text]
        ) { result in
            importVocabulary(result)
        }
        .alert("Vocabulary Import", isPresented: Binding(
            get: { importResult != nil },
            set: { if !$0 { importResult = nil } }
        )) {
            Button("OK") { importResult = nil }
        } message: {
            Text(importResult ?? "")
        }
    }

    private func addTerm() {
        let term = newTerm.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty,
              !store.vocabularyEntries.contains(where: {
                  $0.term.caseInsensitiveCompare(term) == .orderedSame
              }) else { return }
        store.vocabularyEntries.append(VocabularyEntry(term: term))
        store.save()
        newTerm = ""
    }

    /// ShareLink needs a file URL ready before the tap.
    private func writeVocabularyFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Luxicon Vocabulary.json")
        if let data = try? VocabularyJSON.template(existing: store.vocabularyEntries) {
            try? data.write(to: url)
            vocabularyFileURL = url
        }
    }

    private func importVocabulary(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let entries = try VocabularyJSON.parse(Data(contentsOf: url))
            let count = store.importVocabulary(entries)
            importResult = "Imported \(count) terms."
        } catch {
            importResult = "Import failed: \(error.localizedDescription)"
        }
    }
}
