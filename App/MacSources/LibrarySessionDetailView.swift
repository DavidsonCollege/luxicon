import SwiftUI
import LuxiconKit

/// A session read from ~/Luxicon that the Mac doesn't own: a phone push,
/// or a Mac file whose store record is gone. Read-only: summary,
/// transcript, and copy. No edit, reprocess, or delete here.
struct LibrarySessionDetailView: View {
    let session: TranscriptLibrary.Session

    private var isMacOrphan: Bool { session.source == TranscriptExport.macSource }
    private var transcript: MeetingTranscript { session.transcript }

    var body: some View {
        List {
            Section {
                Label {
                    Text(isMacOrphan
                         ? "Recorded on this Mac, but its record is missing, so it can only be read or deleted."
                         : "From your iPhone. Read-only on the Mac.")
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: isMacOrphan ? "laptopcomputer" : "iphone")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .readingRow()
            }
            if let summary = session.summary {
                Section {
                    SummaryOverviewText(overview: summary.overview)
                        .padding(.vertical, 2)
                        .textSelection(.enabled)
                        .readingRow()
                } header: {
                    Text("Summary").readingRow()
                }
            }
            Section {
                ForEach(transcript.speakers, id: \.listID) { s in
                    HStack {
                        Text(s.displayName)
                        Spacer()
                        Text("\(Int((s.talkShare * 100).rounded()))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .readingRow()
                }
            } header: {
                Text("Talk time").readingRow()
            }
            Section {
                ForEach(transcript.turns, id: \.listID) { turn in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(turn.displayName).font(.caption.weight(.semibold))
                            Text(TranscriptExport.timestamp(turn.start))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Text(turn.text)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                    .readingRow()
                }
            } header: {
                Text("Transcript").readingRow()
            }
        }
        .readingWidth()
        .navigationTitle(transcript.date.formatted(date: .abbreviated, time: .omitted))
        .navigationSubtitle(session.person)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Pasteboard.copy(TranscriptExport.markdown(transcript))
                } label: {
                    Label("Copy Transcript", systemImage: "doc.on.doc")
                }
                .help("Copy the transcript as Markdown")
                Button {
                    if let summary = session.summary {
                        Pasteboard.copy(TranscriptExport.summaryMarkdown(summary, transcript: transcript))
                    }
                } label: {
                    Label("Copy Summary", systemImage: "text.quote")
                }
                .disabled(session.summary == nil)
                .help("Copy the summary as Markdown")
            }
        }
    }
}
