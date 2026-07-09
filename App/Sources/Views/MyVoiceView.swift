import SwiftUI
import LuxiconKit

/// Enroll the user's own voice so their turns are auto-labeled in every transcript.
struct MyVoiceView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var recorder = Recorder()
    @State private var isRecording = false
    @State private var isEmbedding = false
    @State private var errorMessage: String?
    @State private var newTerm = ""
    @State private var vocabularyFileURL: URL?
    @State private var importingVocabulary = false
    @State private var importResult: String?

    private static let minSeconds: Double = 8

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Your name") {
                TextField("Name shown in transcripts", text: $store.myName)
                    .onSubmit { store.save() }
            }

            Section {
                if store.myVoiceEmbedding != nil {
                    Label("Voice enrolled", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }

                if isRecording {
                    // Recorder is not Observable; everything that reads it must
                    // live inside the TimelineView so it refreshes each tick.
                    TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Recording… \(TranscriptExport.timestamp(recorder.duration))")
                                .monospacedDigit()
                            LevelMeter(level: recorder.level)
                            Button("Stop & Save") { finishEnrollment() }
                                .disabled(recorder.duration < Self.minSeconds)
                            if recorder.duration < Self.minSeconds {
                                Text("Keep talking until you have at least \(Int(Self.minSeconds)) seconds.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else if isEmbedding {
                    HStack {
                        ProgressView()
                        Text("Analyzing your voice…").padding(.leading, 8)
                    }
                } else {
                    Button(store.myVoiceEmbedding == nil ? "Record Enrollment" : "Re-record Enrollment") {
                        startEnrollment()
                    }
                }
            } header: {
                Text("Voice enrollment")
            } footer: {
                Text("Read anything aloud for ~15 seconds — a paragraph from a book works well. Luxicon stores only a voice fingerprint (256 numbers), not the audio. With your voice enrolled, 1-on-1 transcripts label you and the other person automatically.")
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
                HStack {
                    TextField("Add a name or term", text: $newTerm)
                        .onSubmit { addTerm() }
                    Button("Add") { addTerm() }
                        .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let vocabularyFileURL {
                    ShareLink(item: vocabularyFileURL) {
                        Label("Export Vocabulary Template", systemImage: "square.and.arrow.up")
                    }
                }
                Button {
                    importingVocabulary = true
                } label: {
                    Label("Import Vocabulary…", systemImage: "square.and.arrow.down")
                }
                ShareLink(item: VocabularyJSON.agentPrompt(existing: store.vocabularyEntries)) {
                    Label("Share Agent Prompt", systemImage: "sparkles")
                }
            } header: {
                Text("Vocabulary")
            } footer: {
                Text("Project names, acronyms, jargon — words transcription tends to get wrong. Your name and your people's names are included automatically. Export the JSON template, have a person or AI assistant fill in terms and common mishearings, then import it back.")
            }

            Section {
                TextField("https://example.com/vocabulary.json", text: $store.vocabularySourceURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit {
                        store.save()
                        Task { await store.syncVocabulary() }
                    }
                if !store.vocabularySourceURL.isEmpty {
                    DisclosureGroup("Request Headers") {
                        ForEach($store.vocabularyHeaders) { $header in
                            HStack {
                                TextField("Header", text: $header.name)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .frame(maxWidth: 140)
                                Divider()
                                TextField("Value", text: $header.value)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                            .font(.callout.monospaced())
                        }
                        .onDelete { offsets in
                            store.vocabularyHeaders.remove(atOffsets: offsets)
                            store.save()
                        }
                        Button {
                            store.vocabularyHeaders.append(Store.HTTPHeader())
                        } label: {
                            Label("Add Header", systemImage: "plus")
                        }
                    }
                    Button {
                        store.save()
                        Task { await store.syncVocabulary() }
                    } label: {
                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
            } header: {
                Text("Vocabulary sync")
            } footer: {
                if let error = store.vocabularySyncError {
                    Text("Sync failed: \(error)")
                        .foregroundStyle(.red)
                } else if let last = store.vocabularyLastSync, !store.vocabularySourceURL.isEmpty {
                    Text("Synced \(last.formatted(.relative(presentation: .named))). The file at this URL replaces the vocabulary list on each sync — edit it there, not here. Headers are sent with every request (for example an Authorization token).")
                } else {
                    Text("Point at a JSON vocabulary file (same format as the export) and Luxicon will keep the list synchronized whenever the app opens. The file replaces the vocabulary list; add auth via Request Headers if needed.")
                }
            }

            Section {
                Picker("Engine", selection: $store.asrEngine) {
                    Text("Parakeet (recommended)").tag(ASREngine.parakeet)
                    Text("Qwen3 (experimental)").tag(ASREngine.qwen3)
                }
                .onChange(of: store.asrEngine) { store.save() }
                Toggle("Summarize automatically", isOn: $store.autoSummarize)
                    .onChange(of: store.autoSummarize) { store.save() }
            } header: {
                Text("Transcription engine")
            } footer: {
                Text("Parakeet is fast and battery-friendly; vocabulary is applied as a correction pass. Qwen3 injects your vocabulary directly into the recognizer (better on unusual names) but downloads ~400 MB more and runs slower. Automatic summaries use an on-device language model (one-time ~400 MB download); nothing leaves the phone.")
            }

            Section {
                TextField("Pairing token from `luxicon-mcp listen`", text: $store.syncToken)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .onChange(of: store.syncToken) { store.save() }
                if !store.syncToken.isEmpty {
                    TextField("Mac address (optional, e.g. 192.168.1.5)", text: $store.syncHost)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: store.syncHost) { store.save() }
                    Toggle("Push automatically after each 1-on-1", isOn: $store.autoPushToMac)
                        .onChange(of: store.autoPushToMac) { store.save() }
                }
            } header: {
                Text("Mac sync")
            } footer: {
                Text("Send transcripts and summaries to a Mac running `luxicon-mcp listen`, so you can query them from Claude. Everything stays on your local network. Enter the Mac's address if it isn't found automatically (common on enterprise Wi-Fi that blocks discovery).")
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.footnote)
            }
        }
        .navigationTitle("My Voice")
        .onAppear { writeVocabularyFile() }
        .onChange(of: store.vocabularyEntries) { writeVocabularyFile() }
        .onDisappear {
            if isRecording { _ = recorder.stop() }
            store.save()
        }
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

    private func startEnrollment() {
        errorMessage = nil
        do {
            try recorder.start()
            isRecording = true
        } catch {
            errorMessage = "Could not start recording: \(error.localizedDescription)"
        }
    }

    private func finishEnrollment() {
        let samples = recorder.stop()
        isRecording = false
        isEmbedding = true
        Task {
            do {
                let embedding = try await PipelineService.shared.embedVoice(audio: samples)
                store.myVoiceEmbedding = embedding
                store.save()
            } catch {
                errorMessage = "Enrollment failed: \(error.localizedDescription)"
            }
            isEmbedding = false
        }
    }
}
