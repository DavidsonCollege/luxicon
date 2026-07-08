import SwiftUI
import SitdownKit

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
                Text("First run downloads the speech models (~700 MB).")
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

    var body: some View {
        List {
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
                        UIPasteboard.general.string = TranscriptExport.markdown(transcript)
                    } label: {
                        Label("Copy Markdown", systemImage: "doc.on.doc")
                    }
                    Button {
                        if let data = try? TranscriptExport.json(transcript) {
                            UIPasteboard.general.string = String(decoding: data, as: UTF8.self)
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
        .alert("Rename Speaker", isPresented: Binding(
            get: { renamingSpeakerId != nil },
            set: { if !$0 { renamingSpeakerId = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let id = renamingSpeakerId {
                    var s = session
                    var t = transcript
                    t.setName(renameText.trimmingCharacters(in: .whitespaces), forSpeaker: id)
                    s.transcript = t
                    store.update(s)
                    writeExportFile()
                }
                renamingSpeakerId = nil
            }
            Button("Cancel", role: .cancel) { renamingSpeakerId = nil }
        }
    }

    /// ShareLink needs a file URL; write the markdown next to the temp dir.
    private func writeExportFile() {
        let safeTitle = transcript.title.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeTitle) \(session.date.formatted(.iso8601.year().month().day())).md")
        try? TranscriptExport.markdown(transcript).write(to: url, atomically: true, encoding: .utf8)
        exportURL = url
    }
}
