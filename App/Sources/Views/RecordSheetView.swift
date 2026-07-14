import SwiftUI
import AVFoundation
import LuxiconKit

/// Full-screen recording UI with live caption preview.
///
/// Audio streams to disk while recording (crash-safe: an app death mid-meeting
/// is recovered into a session on next launch). Live captions are a
/// best-effort preview; speaker labels appear in the final diarized pass.
struct RecordSheetView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let person: Person

    @State private var sessionId = UUID()
    @State private var recorder = Recorder()
    @State private var captioner = LiveCaptioner()
    @State private var startError: String?
    @State private var saving = false
    @State private var confirmingDiscard = false
    @State private var isOffRecord = false

    var body: some View {
        NavigationStack {
            // Recorder is not Observable; the TimelineView wraps the whole
            // screen so timer, meter, and buttons re-evaluate each tick.
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                VStack(spacing: 16) {
                    VStack(spacing: 12) {
                        Text(TranscriptExport.timestamp(recorder.duration))
                            .font(.system(size: 48, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        LevelMeter(level: recorder.level)
                    }
                    .padding(.top, 12)

                    captionPanel

                    Label("Make sure \(person.name) knows this conversation is being recorded.",
                          systemImage: "hand.raised")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)

                    if recorder.isInterrupted {
                        VStack(spacing: 8) {
                            Label("Recording paused by another audio session — it usually resumes when the call ends.",
                                  systemImage: "pause.circle")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                            // Escape hatch: CallKit calls don't reliably hand the
                            // session back (see Recorder.resumeFromInterruption).
                            Button {
                                recorder.resumeFromInterruption()
                            } label: {
                                Label("Resume Recording", systemImage: "record.circle")
                                    .font(.subheadline.weight(.medium))
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.horizontal)
                    }
                    if let runtimeError = recorder.runtimeError {
                        Text(runtimeError).font(.footnote).foregroundStyle(.red)
                            .padding(.horizontal)
                    }

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
                    // The 1 s floor mirrors crash recovery's discard threshold:
                    // a sub-second tap would create an unprocessable session.
                    .disabled(saving || !recorder.isRecording || recorder.duration < 1)
                    .padding(.horizontal)

                    Button {
                        goOffRecord()
                    } label: {
                        Label("Go off the record", systemImage: "lock")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .tint(.secondary)
                    .disabled(saving || !recorder.isRecording)
                    .padding(.horizontal)
                }
                .padding(.bottom, 24)
            }
            .navigationTitle("1-on-1 with \(person.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard") { confirmingDiscard = true }
                }
            }
            .interactiveDismissDisabled()
            .confirmationDialog(
                "Discard this recording?", isPresented: $confirmingDiscard, titleVisibility: .visible
            ) {
                Button("Discard Recording", role: .destructive) { discard() }
            } message: {
                Text("The audio cannot be recovered.")
            }
            .onAppear { begin() }
            .onDisappear { store.setRecordingActive(false) }
            .overlay {
                if isOffRecord {
                    OffRecordView(
                        personName: person.name,
                        pausedAt: recorder.duration,
                        onResume: resumeRecording
                    )
                    .transition(.opacity)
                }
            }
        }
    }

    @ViewBuilder
    private var captionPanel: some View {
        Group {
            switch captioner.status {
            case .live where !captioner.text.isEmpty:
                ScrollView {
                    Text(captioner.committed)
                    + Text(captioner.partial).foregroundStyle(.secondary)
                }
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .defaultScrollAnchor(.bottom)
            case .live:
                Text("Listening…")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loading(let message):
                VStack(spacing: 8) {
                    ProgressView()
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unavailable, .idle:
                Text("Live captions unavailable — the full transcript is created when you stop.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private func begin() {
        Task {
            let granted = await AVAudioApplication.requestRecordPermission()
            guard granted else {
                startError = RecorderError.microphoneAccessDenied.errorDescription
                return
            }
            do {
                let fileURL = try store.beginRecording(id: sessionId, person: person)
                recorder.onSamples = captioner.feed
                try recorder.start(writingTo: fileURL)
                store.setRecordingActive(true)
                captioner.start()
                RecordingActivityController.shared.start(personName: person.name)
            } catch {
                startError = "Could not start recording: \(error.localizedDescription)"
            }
        }
    }

    private func goOffRecord() {
        recorder.pause()
        RecordingActivityController.shared.setOffRecord(true, elapsed: recorder.duration)
        withAnimation(.easeInOut(duration: 0.3)) { isOffRecord = true }
    }

    private func resumeRecording() {
        recorder.resume()
        // If resume() failed the recorder stays paused (and sets runtimeError);
        // keep the off-record screen up rather than showing a live-looking screen
        // that isn't capturing. The user can tap Resume again.
        guard !recorder.isPaused else { return }
        RecordingActivityController.shared.setOffRecord(false, elapsed: recorder.duration)
        withAnimation(.easeInOut(duration: 0.3)) { isOffRecord = false }
    }

    private func discard() {
        _ = recorder.stop()
        captioner.reset()
        RecordingActivityController.shared.end()
        store.discardRecording(id: sessionId)
        dismiss()
    }

    private func stopAndSave() {
        saving = true
        // Duration comes from the tally: file-backed recordings no longer
        // keep samples in memory, so stop() returns [] here.
        let duration = recorder.duration
        _ = recorder.stop()
        captioner.stop()
        RecordingActivityController.shared.end()
        do {
            let session = try store.finishRecording(id: sessionId, duration: duration)
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
