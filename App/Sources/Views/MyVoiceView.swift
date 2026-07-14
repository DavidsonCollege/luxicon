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
    @State private var showEnableConfirmation = false
    @State private var showRemoveModelConfirmation = false
    @State private var showingAboutGiving = false

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
                if store.aiSummariesEnabled {
                    // Height-capped preview; the full text (and editing, when
                    // people sync doesn't own it) lives on the pushed screen.
                    NavigationLink {
                        ContextDetailView(
                            title: "About You",
                            text: $store.myContext,
                            syncedExplanation: store.peopleSyncConfigured
                                ? "People sync is on: this text comes from the synced file's “me” entry and can't be edited here — edit the file instead."
                                : nil,
                            editingExplanation: "Background the summarizer uses to interpret your 1-on-1s — your role, team, and current focus.",
                            emptyPrompt: store.peopleSyncConfigured
                                ? "No “me” entry in the synced people file yet — add one there."
                                : "About you — role, team, current focus",
                            onSave: { store.save() }
                        )
                    } label: {
                        ContextPreviewRow(
                            text: store.myContext,
                            emptyPrompt: store.peopleSyncConfigured
                                ? "About you — from the synced people file"
                                : "About you — role, team, current focus"
                        )
                    }
                }
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

            aiSummariesSection

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
                Text(store.vocabularySyncConfigured
                    ? "Words transcription tends to get wrong. The list is synchronized from the URL below and read-only in the app."
                    : "Words transcription tends to get wrong. Add, import, or export them here — or keep the list synchronized from a URL below.")
            }

            SyncSourceSection(
                title: "Vocabulary sync",
                urlPlaceholder: "https://example.com/vocabulary.json",
                sourceURL: $store.vocabularySourceURL,
                headers: $store.vocabularyHeaders,
                lastSync: store.vocabularyLastSync,
                syncError: store.vocabularySyncError,
                idleFooter: "Point at a JSON vocabulary file (same format as the export) and Luxicon will keep the list synchronized whenever the app opens. The file replaces the vocabulary list; add auth via Request Headers if needed.",
                syncedFooter: "The file at this URL replaces the vocabulary list on each sync — the list is read-only in the app; edit the file instead. Headers are sent with every request (for example an Authorization token).",
                onSave: { store.save() },
                onSync: { Task { await store.syncVocabulary() } }
            )

            SyncSourceSection(
                title: "People sync",
                urlPlaceholder: "https://example.com/people.json",
                sourceURL: $store.peopleSourceURL,
                headers: $store.peopleHeaders,
                lastSync: store.peopleLastSync,
                syncError: store.peopleSyncError,
                idleFooter: "Point at a JSON people file (same format as Export People) and Luxicon will keep the roster synchronized whenever the app opens. Syncing adds and updates people (name and context), applies the file's “me” entry to About You, and never removes anyone.",
                syncedFooter: "Syncing adds and updates people (name and context), applies the file's “me” entry to About You, and never removes anyone — remove people manually in the list. While sync is on, context fields are read-only in the app; edit the file instead. Headers are sent with every request (for example an Authorization token).",
                onSave: { store.save() },
                onSync: { Task { await store.syncPeople() } }
            )

            Section {
                ShareLink(item: URL(string: "https://github.com/DavidsonCollege/luxicon/releases")!) {
                    Label("Send installer link to your Mac", systemImage: "square.and.arrow.up")
                }
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
                Text("Send transcripts and summaries to a Mac running `luxicon-mcp listen`, so you can query them from Claude. Everything stays on your local network. Use “Send installer link to your Mac” to AirDrop the listener installer over, then enter the Mac's address if it isn't found automatically (common on enterprise Wi-Fi that blocks discovery).")
            }

            Section {
                Button {
                    showingAboutGiving = true
                } label: {
                    HStack(spacing: 12) {
                        Image(decorative: "AppIconLarge")
                            .resizable()
                            .frame(width: 30, height: 30)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        Text("About Luxicon & Giving")
                            .foregroundStyle(.primary)
                    }
                }
            } header: {
                Text("Davidson College")
            } footer: {
                Text("Luxicon is a free, open-source service of Davidson College.")
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.footnote)
            }
        }
        .navigationTitle("My Voice")
        .sheet(isPresented: $showingAboutGiving) {
            AboutGivingView()
        }
        .onDisappear {
            if isRecording { _ = recorder.stop() }
            store.save()
        }
    }

    /// Opt-in AI features: summaries, list labels, personal context. The
    /// enable flow is explicit about the ~2.5 GB on-device model download;
    /// when off, all summary/context UI in the app is hidden.
    @ViewBuilder
    private var aiSummariesSection: some View {
        @Bindable var store = store
        Section {
            if let stage = store.summaryModelDownloadStage {
                HStack {
                    ProgressView()
                    Text(stage).font(.footnote).foregroundStyle(.secondary).padding(.leading, 8)
                }
            } else if store.aiSummariesEnabled {
                Label("AI summaries enabled", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Picker("Engine", selection: engineBinding) {
                    Text(SummaryEngine.appleIntelligence.displayName)
                        .tag(SummaryEngine.appleIntelligence)
                        .selectionDisabled(AppleIntelligence.status != .available)
                    Text(SummaryEngine.gemma.displayName)
                        .tag(SummaryEngine.gemma)
                }
                Toggle("Summarize automatically", isOn: $store.autoSummarize)
                    .onChange(of: store.autoSummarize) { store.save() }
                if let error = store.summaryModelError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                Button(role: .destructive) {
                    showRemoveModelConfirmation = true
                } label: {
                    Label("Turn Off AI Summaries…", systemImage: "trash")
                }
            } else {
                Button {
                    showEnableConfirmation = true
                } label: {
                    Label("Enable AI Summaries…", systemImage: "sparkles")
                }
                if let error = store.summaryModelError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
        } header: {
            Text("AI summaries")
        } footer: {
            Text(footerText)
        }
        .confirmationDialog(
            "Enable AI summaries?",
            isPresented: $showEnableConfirmation,
            titleVisibility: .visible
        ) {
            if AppleIntelligence.status == .available {
                Button("Use Apple Intelligence") {
                    store.enableAISummaries(engine: .appleIntelligence)
                }
            }
            Button("Download \(SummaryService.approximateDownload) & Use Gemma") {
                store.enableAISummaries(engine: .gemma)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(enableDialogMessage)
        }
        .confirmationDialog(
            "Turn off AI summaries?",
            isPresented: $showRemoveModelConfirmation,
            titleVisibility: .visible
        ) {
            if MeetingSummarizer.isModelDownloaded(.gemma4) {
                Button("Remove Gemma Model (frees \(SummaryService.approximateDownload))", role: .destructive) {
                    store.disableAISummaries(deleteModel: true)
                }
                Button("Keep Model, Just Turn Off") {
                    store.disableAISummaries(deleteModel: false)
                }
            } else {
                Button("Turn Off", role: .destructive) {
                    store.disableAISummaries(deleteModel: false)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(MeetingSummarizer.isModelDownloaded(.gemma4)
                ? "Existing summaries stay on your sessions either way. Keeping the model means re-enabling later is instant; removing it frees the space but re-enabling downloads it again."
                : "Existing summaries stay on your sessions.")
        }
    }

    /// Switching engines goes through the Store so a failed switch (e.g. an
    /// abandoned Gemma download) flips back to the previous engine.
    private var engineBinding: Binding<SummaryEngine> {
        Binding(
            get: { store.summaryEngine ?? .gemma },
            set: { store.switchSummaryEngine(to: $0) }
        )
    }

    private var footerText: String {
        var parts: [String] = []
        if store.aiSummariesEnabled {
            parts.append("Each 1-on-1 gets a summary and a one-line topic label, "
                + "informed by the background notes you keep about yourself and each "
                + "person. Everything runs on this phone.")
            if store.summaryEngine == .appleIntelligence {
                if ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27 {
                    parts.append("Long meetings are summarized in sections and "
                        + "stitched together. iOS 27 summarizes longer meetings in one pass.")
                }
            } else if let reason = appleUnavailableFootnote {
                parts.append(reason)
            }
        } else {
            parts.append("Summarize each 1-on-1 on this phone and use your background "
                + "notes about people to interpret them — nothing leaves the phone.")
            parts.append(AppleIntelligence.status == .available
                ? "Uses Apple Intelligence, or a downloadable \(SummaryService.approximateDownload) on-device model."
                : "Requires a one-time \(SummaryService.approximateDownload) model download to this device.")
        }
        return parts.joined(separator: " ")
    }

    /// Why the Apple Intelligence picker row is disabled, in actionable terms.
    private var appleUnavailableFootnote: String? {
        switch AppleIntelligence.status {
        case .available: return nil
        case .osTooOld:
            return "Apple Intelligence requires iOS 26 or later."
        case .deviceNotEligible:
            return "Apple Intelligence requires iPhone 15 Pro or later — Gemma works on this phone."
        case .notEnabled:
            return "Turn on Apple Intelligence in Settings to use it here."
        case .modelNotReady:
            return "Apple Intelligence is preparing on this iPhone — try again shortly."
        }
    }

    private var enableDialogMessage: String {
        var message = AppleIntelligence.status == .available
            ? "Apple Intelligence uses the model built into this iPhone — no download. "
                + "Gemma is a one-time \(SummaryService.approximateDownload) download. "
                + "Either way, summaries are generated only on-device."
            : "The model is stored on this iPhone and used only on-device. "
                + "Wi-Fi is recommended for the download."
        if let free = Store.availableDiskSpace() {
            let freeText = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
            message += " You have \(freeText) available."
            if free < 4_000_000_000 {
                message += " Storage is tight — consider freeing space first."
            }
        }
        return message
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
