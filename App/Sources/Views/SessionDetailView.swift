import SwiftUI
import UniformTypeIdentifiers
import LuxiconKit

/// One session: processing state, transcript, stats, export.
struct SessionDetailView: View {
    @Environment(Store.self) private var store
    let sessionId: UUID

    private var session: SessionRecord? {
        store.sessions.first { $0.id == sessionId }
    }

    var body: some View {
        Group {
            if let session {
                content(session)
            } else {
                ContentUnavailableView("Session deleted", systemImage: "trash")
            }
        }
        .navigationTitle(session?.date.formatted(date: .abbreviated, time: .omitted) ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func content(_ session: SessionRecord) -> some View {
        switch session.status {
        case .recorded:
            ContentUnavailableView {
                Label("Not transcribed yet", systemImage: "waveform.badge.magnifyingglass")
            } description: {
                Text("Audio is saved. Transcription runs entirely on this device.")
            } actions: {
                Button("Transcribe") { store.startProcessing(session) }
                    .buttonStyle(.borderedProminent)
            }
        case .processing:
            let info = store.processing.info(for: session.id)
            VStack(spacing: 16) {
                ProgressView(value: info?.fraction ?? 0)
                    .padding(.horizontal, 40)
                Text(info?.stage ?? "Working…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("First run may download speech models (up to ~700 MB).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        case .failed:
            ContentUnavailableView {
                Label("Transcription failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(session.errorMessage ?? "Unknown error")
            } actions: {
                Button("Retry") { store.startProcessing(session) }
                    .buttonStyle(.borderedProminent)
            }
        case .ready:
            if let transcript = session.transcript {
                TranscriptView(session: session, transcript: transcript)
            }
        }
    }
}

struct TranscriptView: View {
    @Environment(Store.self) private var store
    let session: SessionRecord
    let transcript: MeetingTranscript

    @State private var renamingSpeakerId: Int?
    @State private var renameText = ""
    @State private var exportURL: URL?
    @State private var summaryURL: URL?
    @State private var isPushing = false

    var body: some View {
        List {
            summarySection
            macSyncSection
            Section("Talk time") {
                ForEach(transcript.speakers, id: \.speakerId) { s in
                    HStack {
                        Text(s.displayName)
                        Spacer()
                        Text("\(Int((s.talkShare * 100).rounded()))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        renamingSpeakerId = s.speakerId
                        renameText = s.speakerName ?? ""
                    }
                }
            }
            Section("Transcript") {
                ForEach(transcript.turns) { turn in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(turn.displayName).font(.caption.weight(.semibold))
                            Text(TranscriptExport.timestamp(turn.start))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Text(turn.text)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("Share Markdown", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button {
                        copyToPasteboard(TranscriptExport.markdown(transcript))
                    } label: {
                        Label("Copy Markdown", systemImage: "doc.on.doc")
                    }
                    Button {
                        if let data = try? TranscriptExport.json(transcript) {
                            copyToPasteboard(String(decoding: data, as: UTF8.self))
                        }
                    } label: {
                        Label("Copy JSON", systemImage: "curlybraces")
                    }
                    Button {
                        store.startProcessing(session)
                    } label: {
                        Label("Re-transcribe", systemImage: "arrow.clockwise")
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .onAppear { writeExportFile() }
        .onChange(of: session.summary) { writeExportFile() }
        .onDisappear {
            // Transcript copies don't belong in tmp longer than the view.
            if let exportURL { try? FileManager.default.removeItem(at: exportURL) }
            if let summaryURL { try? FileManager.default.removeItem(at: summaryURL) }
        }
        .alert("Rename Speaker", isPresented: Binding(
            get: { renamingSpeakerId != nil },
            set: { if !$0 { renamingSpeakerId = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                let name = renameText.trimmingCharacters(in: .whitespaces)
                if let id = renamingSpeakerId, !name.isEmpty {
                    var s = session
                    var t = transcript
                    t.setName(name, forSpeaker: id)
                    s.transcript = t
                    // The Mac copy (if any) has the old name: back to pending.
                    s.lastPushDate = nil
                    s.lastPushError = nil
                    store.update(s)
                    writeExportFile()
                }
                renamingSpeakerId = nil
            }
            Button("Cancel", role: .cancel) { renamingSpeakerId = nil }
        }
    }

    /// Hidden entirely while AI summaries are off — except that summaries
    /// generated before the feature was turned off stay readable/sharable
    /// (regeneration still requires re-enabling in My Voice).
    @ViewBuilder
    private var summarySection: some View {
        if store.aiSummariesEnabled || session.summary != nil {
            Section("Summary") {
                if let summary = session.summary {
                    SummaryOverviewText(overview: summary.overview)
                        .padding(.vertical, 2)
                    if let summaryURL {
                        ShareLink(item: summaryURL) {
                            Label("Share Summary", systemImage: "square.and.arrow.up")
                        }
                    }
                    if store.aiSummariesEnabled {
                        Button {
                            var s = session
                            s.summary = nil
                            s.listLabel = nil
                            store.update(s)
                            store.startSummarizing(s)
                        } label: {
                            Label("Regenerate Summary", systemImage: "arrow.clockwise")
                        }
                    }
                } else if let stage = store.processing.summarizing[session.id] {
                    HStack {
                        ProgressView()
                        Text(stage).font(.footnote).foregroundStyle(.secondary).padding(.leading, 8)
                    }
                } else {
                    if let error = store.processing.summarizeError[session.id] {
                        Label {
                            Text(error).font(.footnote).foregroundStyle(.red)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                    Button {
                        store.startSummarizing(session)
                    } label: {
                        Label("Generate Summary", systemImage: "sparkles")
                    }
                }
            }
        }
    }

    /// Push status + diagnostics; rendered only while Mac Sync is enabled.
    /// TranscriptView re-inits with the updated record after each push, so
    /// the section always reflects the last recorded outcome.
    @ViewBuilder
    private var macSyncSection: some View {
        if !store.syncToken.isEmpty {
            Section("Mac Sync") {
                switch session.macSyncState {
                case .synced(let date):
                    Label {
                        Text("Pushed to Mac \(date.formatted(.relative(presentation: .named)))")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                case .failed(let message):
                    Label {
                        Text(message).foregroundStyle(.red)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    pushButton("Retry Push")
                case .pending:
                    Label {
                        Text("Not pushed yet").foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "laptopcomputer")
                            .foregroundStyle(.secondary)
                    }
                    pushButton("Push to Mac")
                }
            }
        }
    }

    private func pushButton(_ title: String) -> some View {
        Button {
            isPushing = true
            Task {
                await store.pushToMac(session)
                isPushing = false
            }
        } label: {
            if isPushing {
                HStack {
                    ProgressView()
                    Text("Pushing…").padding(.leading, 8)
                }
            } else {
                Label(title, systemImage: "laptopcomputer.and.arrow.down")
            }
        }
        .disabled(isPushing)
    }

    /// Local-only + expiring: transcripts shouldn't hop devices via Universal
    /// Clipboard or linger in the pasteboard indefinitely.
    private func copyToPasteboard(_ text: String) {
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: text]],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(10 * 60),
            ])
    }

    /// ShareLink needs a file URL; write the markdown next to the temp dir.
    private func writeExportFile() {
        let safeTitle = transcript.title.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeTitle) \(session.date.formatted(.iso8601.year().month().day())).md")
        try? TranscriptExport.markdown(transcript).write(to: url, atomically: true, encoding: .utf8)
        exportURL = url
        if let summary = session.summary {
            let sURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("Summary — \(safeTitle) \(session.date.formatted(.iso8601.year().month().day())).md")
            try? TranscriptExport.summaryMarkdown(summary, transcript: transcript)
                .write(to: sURL, atomically: true, encoding: .utf8)
            summaryURL = sURL
        } else {
            summaryURL = nil
        }
    }
}

/// Block-level renderer for the stored summary markdown. SwiftUI's Text
/// markdown is inline-only — newlines collapse to spaces and "- " markers
/// render as literal text — so lay out paragraphs and bullet rows ourselves
/// and keep inline markdown (bold) within each block.
private struct SummaryOverviewText: View {
    let overview: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(MeetingSummarizer.overviewBlocks(overview).enumerated()),
                    id: \.offset) { _, block in
                switch block {
                case .paragraph(let text):
                    Text(LocalizedStringKey(text))
                case .bullet(let level, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        Text(LocalizedStringKey(text))
                    }
                    .padding(.leading, CGFloat(level + 1) * 12)
                }
            }
        }
        .font(.callout)
    }
}
