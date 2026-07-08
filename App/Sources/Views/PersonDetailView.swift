import SwiftUI
import SitdownKit

/// One direct report: their session history + record button.
struct PersonDetailView: View {
    @Environment(Store.self) private var store
    let person: Person
    @State private var showingRecorder = false

    var body: some View {
        let sessions = store.sessions(for: person)
        List {
            Section {
                Button {
                    showingRecorder = true
                } label: {
                    Label("Record 1-on-1", systemImage: "record.circle")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
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
        .fullScreenCover(isPresented: $showingRecorder) {
            RecordSheetView(person: person)
        }
    }
}

struct SessionRow: View {
    @Environment(Store.self) private var store
    let session: SessionRecord

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(session.date.formatted(date: .abbreviated, time: .shortened))
                Text(TranscriptExport.timestamp(session.duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch session.status {
            case .recorded:
                Image(systemName: "circle.dashed").foregroundStyle(.secondary)
            case .processing:
                ProgressView()
            case .ready:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
    }
}
