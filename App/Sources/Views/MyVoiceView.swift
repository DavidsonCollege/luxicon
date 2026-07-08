import SwiftUI
import SitdownKit

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
                TextField("Name shown in transcripts", text: $store.myName)
                    .onSubmit { store.save() }
            }

            Section {
                if store.myVoiceEmbedding != nil {
                    Label("Voice enrolled", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }

                if isRecording {
                    TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Recording… \(TranscriptExport.timestamp(recorder.duration))")
                                .monospacedDigit()
                            LevelMeter(level: recorder.level)
                                .padding(.horizontal, 0)
                        }
                    }
                    Button("Stop & Save") { finishEnrollment() }
                        .disabled(recorder.duration < Self.minSeconds)
                    Text("Keep talking until you have at least \(Int(Self.minSeconds)) seconds.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                Text("Read anything aloud for ~15 seconds — a paragraph from a book works well. Sitdown stores only a voice fingerprint (256 numbers), not the audio. With your voice enrolled, 1-on-1 transcripts label you and the other person automatically.")
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
