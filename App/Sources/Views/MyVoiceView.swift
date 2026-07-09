import SwiftUI
import AVFoundation
import LuxiconKit

/// Enroll the user's own voice so their turns are auto-labeled in every transcript.
struct MyVoiceView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var recorder = Recorder()
    @State private var isRecording = false
    @State private var isEmbedding = false
    @State private var errorMessage: String?

    private static let minSeconds: Double = 8

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Your name") {
                HStack(spacing: 12) {
                    AvatarPicker(fileName: store.myPhotoFileName, name: store.myName) { data in
                        store.setMyPhoto(data)
                    }
                    TextField("Name shown in transcripts", text: $store.myName)
                        .onSubmit { store.save() }
                }
                TextField("About you — role, team, current focus", text: $store.myContext, axis: .vertical)
                    .lineLimit(2...6)
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
                NavigationLink {
                    VocabularyListView()
                } label: {
                    HStack {
                        Text("Manage Vocabulary")
                        Spacer()
                        Text("\(store.vocabularyEntries.count) terms")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Vocabulary")
            } footer: {
                Text("Words transcription tends to get wrong. Add, import, or export them here — or keep the list synchronized from a URL below.")
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
                        // Id-based bindings, not ForEach($...): rows outlive
                        // removal by one render pass, and a positional binding
                        // read after the array shrinks crashes.
                        ForEach(store.vocabularyHeaders) { header in
                            HStack {
                                // Explicit remove button: swipe-to-delete is
                                // unreliable inside a DisclosureGroup.
                                Button {
                                    store.vocabularyHeaders.removeAll { $0.id == header.id }
                                    store.save()
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                                TextField("Header", text: headerBinding(header.id, \.name))
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .frame(maxWidth: 140)
                                Divider()
                                TextField("Value", text: headerBinding(header.id, \.value))
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
        .onDisappear {
            if isRecording { _ = recorder.stop() }
            store.save()
        }
    }

    /// Binding into a header row by id; reads return "" and writes no-op
    /// once the row has been removed, so a stale row can't trap.
    private func headerBinding(
        _ id: UUID, _ keyPath: WritableKeyPath<Store.HTTPHeader, String>
    ) -> Binding<String> {
        Binding(
            get: { store.vocabularyHeaders.first { $0.id == id }?[keyPath: keyPath] ?? "" },
            set: { newValue in
                guard let i = store.vocabularyHeaders.firstIndex(where: { $0.id == id })
                else { return }
                store.vocabularyHeaders[i][keyPath: keyPath] = newValue
            }
        )
    }

    private func startEnrollment() {
        errorMessage = nil
        Task {
            let granted = await AVAudioApplication.requestRecordPermission()
            guard granted else {
                errorMessage = RecorderError.microphoneAccessDenied.errorDescription
                return
            }
            do {
                try recorder.start()
                isRecording = true
            } catch {
                errorMessage = "Could not start recording: \(error.localizedDescription)"
            }
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
