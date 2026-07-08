import SwiftUI
import SitdownKit

/// Full-screen recording UI. Saves the WAV and kicks off processing on stop.
struct RecordSheetView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let person: Person

    @State private var recorder = Recorder()
    @State private var startError: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    VStack(spacing: 24) {
                        Text(TranscriptExport.timestamp(recorder.duration))
                            .font(.system(size: 56, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        LevelMeter(level: recorder.level)
                    }
                }

                Text("Recording 1-on-1 with \(person.name)")
                    .font(.headline)

                Label("Make sure \(person.name) knows this conversation is being recorded.",
                      systemImage: "hand.raised")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                Spacer()

                if let startError {
                    Text(startError).font(.footnote).foregroundStyle(.red)
                }

                Button {
                    stopAndSave()
                } label: {
                    Label(saving ? "Saving…" : "Stop & Transcribe", systemImage: "stop.circle.fill")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(saving || !recorder.isRecording)
                .padding(.horizontal)
            }
            .padding(.bottom, 24)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard") {
                        _ = recorder.stop()
                        dismiss()
                    }
                }
            }
            .interactiveDismissDisabled()
            .onAppear {
                do {
                    try recorder.start()
                } catch {
                    startError = "Could not start recording: \(error.localizedDescription)"
                }
            }
        }
    }

    private func stopAndSave() {
        saving = true
        let samples = recorder.stop()
        let session = SessionRecord(
            personId: person.id,
            title: "1-on-1 with \(person.name)",
            date: Date(),
            duration: Double(samples.count) / Double(Recorder.sampleRate)
        )
        do {
            try WAVFile.write(
                samples: samples,
                sampleRate: Recorder.sampleRate,
                to: store.audioURL(for: session)
            )
            store.addSession(session)
            store.startProcessing(session)
            dismiss()
        } catch {
            startError = "Could not save recording: \(error.localizedDescription)"
            saving = false
        }
    }
}

/// Simple RMS level meter.
struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(.tint)
                    .frame(width: geo.size.width * CGFloat(min(level, 1)))
                    .animation(.linear(duration: 0.1), value: level)
            }
        }
        .frame(height: 8)
        .padding(.horizontal, 48)
    }
}
