import SwiftUI
import LuxiconKit

/// One direct report: their session history + record button.
struct PersonDetailView: View {
    @Environment(Store.self) private var store
    let person: Person
    @State private var showingRecorder = false
    @State private var historyURL: URL?
    @State private var historyJSONURL: URL?
    @State private var pushResult: String?

    var body: some View {
        let sessions = store.sessions(for: person)
        List {
            Section {
                // Route values carry a stale Person copy; read the photo from
                // the store so a fresh pick shows up immediately.
                AvatarPicker(
                    fileName: store.person(id: person.id)?.photoFileName,
                    name: person.name,
                    size: 88
                ) { data in
                    store.setPhoto(data, for: person.id)
                }
                .frame(maxWidth: .infinity)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section {
                Button {
                    showingRecorder = true
                } label: {
                    // Explicit HStack: List rows suppress Label icons while
                    // still skewing centering; this keeps icon + text centered.
                    HStack(spacing: 8) {
                        Image(systemName: "record.circle")
                        Text("Record 1-on-1")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            // Personal context is part of the opt-in AI summaries feature
            // (My Voice → AI summaries); hidden while it's off. The row is a
            // height-capped preview; the full text (and editing, when people
            // sync doesn't own it) lives on the pushed screen.
            if store.aiSummariesEnabled {
                Section {
                    NavigationLink {
                        ContextDetailView(
                            title: "Context",
                            text: contextBinding,
                            syncedExplanation: store.peopleSyncConfigured
                                ? "People sync is on: \(person.name)'s context comes from the synced file and can't be edited here — edit the file instead."
                                : nil,
                            editingExplanation: "Background the summarizer uses to interpret your 1-on-1s — e.g. “Senior sysadmin; runs the identity platform; discussing promotion this quarter.” Stays on this device unless you configure people sync — then the synced file's context wins.",
                            emptyPrompt: store.peopleSyncConfigured
                                ? "No context yet — add \(person.name) to the synced people file."
                                : "Role, projects, current threads…",
                            onSave: { store.save() }
                        )
                    } label: {
                        ContextPreviewRow(
                            text: store.person(id: person.id)?.context ?? "",
                            emptyPrompt: store.peopleSyncConfigured
                                ? "No context yet — add \(person.name) to the synced people file."
                                : "Role, projects, current threads…"
                        )
                    }
                } header: {
                    Text("Context")
                } footer: {
                    Text("Background the summarizer uses to interpret your 1-on-1s.")
                }
            }

            if sessions.isEmpty {
                ContentUnavailableView(
                    "No sessions yet",
                    systemImage: "waveform",
                    description: Text("Recordings with \(person.name) will appear here.")
                )
            } else {
                Section("Sessions") {
                    ForEach(sessions) { session in
                        NavigationLink {
                            SessionDetailView(sessionId: session.id)
                        } label: {
                            SessionRow(session: session)
                        }
                    }
                    .onDelete { indexSet in
                        for i in indexSet { store.deleteSession(sessions[i]) }
                    }
                }
            }
        }
        .navigationTitle(person.name)
        .toolbar {
            if !readyTranscripts.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if let historyURL {
                            ShareLink(item: historyURL) {
                                Label("Share Full History (Markdown)", systemImage: "square.and.arrow.up")
                            }
                        }
                        if let historyJSONURL {
                            ShareLink(item: historyJSONURL) {
                                Label("Share Full History (JSON)", systemImage: "curlybraces")
                            }
                        }
                        if !store.syncToken.isEmpty {
                            Button {
                                Task {
                                    let (ok, total) = await store.pushAll(for: person)
                                    pushResult = "Pushed \(ok) of \(total) to your Mac."
                                }
                            } label: {
                                Label("Push All to Mac", systemImage: "laptopcomputer.and.arrow.down")
                            }
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .onAppear { writeHistoryFiles() }
        .onDisappear {
            store.save()
            // Full-history exports don't belong in tmp longer than the view.
            if let historyURL { try? FileManager.default.removeItem(at: historyURL) }
            if let historyJSONURL { try? FileManager.default.removeItem(at: historyJSONURL) }
        }
        .alert("Mac Sync", isPresented: Binding(
            get: { pushResult != nil }, set: { if !$0 { pushResult = nil } }
        )) { Button("OK") { pushResult = nil } } message: { Text(pushResult ?? "") }
        .onChange(of: store.sessions) { writeHistoryFiles() }
        .fullScreenCover(isPresented: $showingRecorder) {
            RecordSheetView(person: person)
        }
    }

    /// Route values carry a stale Person copy; edit context via the store.
    private var contextBinding: Binding<String> {
        Binding(
            get: { store.person(id: person.id)?.context ?? "" },
            set: { newValue in
                guard let i = store.people.firstIndex(where: { $0.id == person.id }) else { return }
                store.people[i].context = newValue.isEmpty ? nil : newValue
            }
        )
    }

    /// Transcribed sessions oldest-first, as LongitudinalExport expects.
    private var readyTranscripts: [MeetingTranscript] {
        store.sessions(for: person)
            .filter { $0.status == .ready }
            .compactMap(\.transcript)
            .sorted { $0.date < $1.date }
    }

    private func writeHistoryFiles() {
        let transcripts = readyTranscripts
        guard !transcripts.isEmpty else {
            historyURL = nil
            historyJSONURL = nil
            return
        }
        let base = "1-on-1 History — \(person.name)"
        let md = FileManager.default.temporaryDirectory.appendingPathComponent("\(base).md")
        try? LongitudinalExport.markdown(personName: person.name, transcripts: transcripts)
            .write(to: md, atomically: true, encoding: .utf8)
        historyURL = md
        let json = FileManager.default.temporaryDirectory.appendingPathComponent("\(base).json")
        if let data = try? LongitudinalExport.json(
            personName: person.name, transcripts: transcripts, generatedAt: Date()) {
            try? data.write(to: json)
            historyJSONURL = json
        }
    }
}

struct SessionRow: View {
    @Environment(Store.self) private var store
    let session: SessionRecord

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.date.formatted(date: .abbreviated, time: .shortened))
                if let listLabel = session.listLabel {
                    Text(listLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(TranscriptExport.timestamp(session.duration))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            switch session.status {
            case .recorded:
                Image(systemName: "circle.dashed").foregroundStyle(.secondary)
            case .processing:
                ProgressView()
            case .ready:
                if !store.syncToken.isEmpty {
                    syncBadge
                }
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
    }

    /// Small Mac Sync state mark, shown only while Mac Sync is enabled.
    @ViewBuilder
    private var syncBadge: some View {
        switch session.macSyncState {
        case .synced:
            Image(systemName: "laptopcomputer")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "laptopcomputer.trianglebadge.exclamationmark")
                .font(.caption)
                .foregroundStyle(.orange)
        case .pending:
            Image(systemName: "laptopcomputer")
                .font(.caption)
                .foregroundStyle(.quaternary)
        }
    }
}
