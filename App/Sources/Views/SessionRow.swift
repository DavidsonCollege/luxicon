import SwiftUI
import LuxiconKit

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
                    .accessibilityLabel("Not transcribed")
            case .processing:
                ProgressView()
                    .accessibilityLabel("Transcribing")
            case .ready:
                #if os(iOS)
                if !store.syncToken.isEmpty {
                    syncBadge
                }
                #endif
                // Without a label, VoiceOver reads the symbol as "Selected".
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    .accessibilityLabel("Transcribed")
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .accessibilityLabel("Transcription failed")
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
