import AppKit
import AVFoundation
import SwiftUI
import LuxiconKit

/// Content of the "Recording" window. One recording at a time: the session
/// view is keyed by the request, so each new recording starts from fresh
/// state even if SwiftUI reuses the window's content.
struct MacRecordView: View {
    static let windowID = "record"
    static let size = CGSize(width: 560, height: 640)

    @Environment(MacNavigation.self) private var navigation

    var body: some View {
        Group {
            if let person = navigation.recordingPerson {
                MacRecordingSession(person: person)
                    .id(navigation.recordingID)
            } else {
                ContentUnavailableView(
                    "No Recording", systemImage: "record.circle",
                    description: Text("Choose File → New Recording… (⌘N) to record a 1-on-1."))
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }
}

/// One recording with one person, on the Mac's default input device.
///
/// Mirrors the iPhone's record sheet: audio streams to disk as it's captured
/// (a crash is recovered into a session on next launch), live captions are a
/// best-effort preview, and Stop & Transcribe starts the full pipeline. If
/// the Mac goes to sleep, the recording stops and is saved; processing
/// starts on wake (`MacNavigation.handleWake`).
private struct MacRecordingSession: View {
    @Environment(Store.self) private var store
    @Environment(MacNavigation.self) private var navigation
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL
    let person: Person

    @State private var sessionId = UUID()
    @State private var recorder = Recorder()
    @State private var captioner = LiveCaptioner()
    @State private var closeGuard = WindowCloseGuard()
    @State private var inputName: String?
    @State private var startError: String?
    @State private var microphoneDenied = false
    @State private var began = false
    @State private var saving = false
    /// Saved or discarded: the window is on its way out.
    @State private var finished = false
    @State private var confirmingDiscard = false
    @State private var confirmingClose = false
    @State private var isOffRecord = false

    var body: some View {
        // Recorder is not Observable; the TimelineView re-evaluates the
        // timer, meter, and buttons each tick.
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            VStack(spacing: 14) {
                VStack(spacing: 10) {
                    Text(TranscriptExport.timestamp(recorder.duration))
                        .font(.system(size: 48, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    LevelMeter(level: recorder.level)
                }
                .padding(.top, 8)
                // Off the record, the overlay covers everything here, and
                // VoiceOver shouldn't reach it behind the overlay either.
                // (Per element: a hidden(false) container would un-hide the
                // Space-to-stop button's own hidden(true).)
                .accessibilityHidden(isOffRecord)

                captionPanel
                    .accessibilityHidden(isOffRecord)

                VStack(spacing: 6) {
                    // Decorative icons: VoiceOver reads just the text (the
                    // hand symbol would otherwise be announced as "Block").
                    Label("Input: \(inputName ?? "No input device")", systemImage: "mic")
                        .font(.callout)
                        .labelStyle(DecorativeIconLabelStyle())
                    Label("Make sure \(person.name) knows this conversation is being recorded.",
                          systemImage: "hand.raised")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .labelStyle(DecorativeIconLabelStyle())
                    Label("Keep the lid open — closing it stops recording.", systemImage: "laptopcomputer")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .labelStyle(DecorativeIconLabelStyle())
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .accessibilityHidden(isOffRecord)

                statusMessages
                    .accessibilityHidden(isOffRecord)

                Button {
                    stopAndSave()
                } label: {
                    Label(saving ? "Saving…" : "Stop & Transcribe", systemImage: "stop.circle.fill")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.red)
                .keyboardShortcut(".", modifiers: .command)
                // The 1 s floor mirrors crash recovery's discard threshold:
                // a sub-second stop would create an unprocessable session.
                .disabled(!canStop)
                .accessibilityHidden(isOffRecord)
                .background {
                    // Space also stops (a second shortcut needs its own button).
                    Button("Stop & Transcribe") { stopAndSave() }
                        .keyboardShortcut(.space, modifiers: [])
                        .disabled(!canStop)
                        .opacity(0)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal)

                HStack {
                    Button("Discard…", role: .destructive) { confirmingDiscard = true }
                        .disabled(saving || finished)
                    Spacer()
                    Button {
                        goOffRecord()
                    } label: {
                        Label("Go Off the Record", systemImage: "lock")
                    }
                    .disabled(saving || !recorder.isRecording)
                }
                .padding(.horizontal)
                .accessibilityHidden(isOffRecord)
            }
            .padding(.bottom, 20)
        }
        .navigationTitle("1-on-1 with \(person.name)")
        .confirmationDialog(
            "Discard this recording?", isPresented: $confirmingDiscard, titleVisibility: .visible
        ) {
            Button("Discard Recording", role: .destructive) { discard() }
        } message: {
            Text("The audio cannot be recovered.")
        }
        .overlay {
            if isOffRecord {
                OffRecordView(personName: person.name, pausedAt: recorder.duration, onResume: resumeRecording)
                    .transition(.opacity)
            }
        }
        // On the overlay's host so it doesn't collide with the discard dialog.
        .background {
            Color.clear
                .alert("Stop and save this recording?", isPresented: $confirmingClose) {
                    Button("Save") { answerClose(.save) }
                    Button("Discard", role: .destructive) { answerClose(.discard) }
                    Button("Keep Recording", role: .cancel) { answerClose(.keep) }
                } message: {
                    Text("Save stops the recording and transcribes it. Discarded audio cannot be recovered.")
                }
        }
        .background(WindowAccessor { closeGuard.attach(to: $0) })
        .onChange(of: navigation.pendingQuit) { _, pending in
            if pending { askBeforeQuitting() }
        }
        .onAppear(perform: begin)
        .onDisappear(perform: cleanUp)
        .task {
            // The default input can change mid-recording (AirPods connect,
            // a USB mic is unplugged); the Recorder follows it.
            while !Task.isCancelled {
                let name = AudioInputName.current()
                if name != inputName {
                    inputName = name
                    #if DEBUG
                    DebugRecording.log("input device: \(name ?? "none")")
                    #endif
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        #if DEBUG
        .task { await DebugRecording.runHooks(recorder: recorder, closeGuard: closeGuard, stop: { stopAndSave() }) }
        #endif
    }

    /// Off the record, the stop button is covered, and its shortcuts
    /// (⌘. and Space) must not reach it either.
    private var canStop: Bool {
        !saving && !finished && !isOffRecord && recorder.isRecording && recorder.duration >= 1
    }

    @ViewBuilder
    private var statusMessages: some View {
        if recorder.isInterrupted {
            VStack(spacing: 8) {
                Label("Recording paused by another audio session — it usually resumes when the call ends.",
                      systemImage: "pause.circle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                Button {
                    recorder.resumeFromInterruption()
                } label: {
                    Label("Resume Recording", systemImage: "record.circle")
                }
            }
            .padding(.horizontal)
        }
        if let runtimeError = recorder.runtimeError {
            Text(runtimeError).font(.footnote).foregroundStyle(.red)
                .padding(.horizontal)
        }
        if microphoneDenied {
            VStack(spacing: 8) {
                Text(RecorderError.microphoneAccessDenied.errorDescription ?? "")
                    .font(.footnote)
                    .foregroundStyle(.red)
                Button("Open System Settings") {
                    openURL(SystemSettings.microphonePrivacyURL)
                }
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal)
        }
        if let startError {
            Text(startError).font(.footnote).foregroundStyle(.red)
                .padding(.horizontal)
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

    // MARK: - Recording lifecycle

    private func begin() {
        guard !began else { return }
        began = true
        inputName = AudioInputName.current()
        closeGuard.shouldClose = {
            // Closing mid-recording asks first; otherwise close freely.
            guard recorder.isRecording, !saving, !finished else { return true }
            confirmingClose = true
            #if DEBUG
            DebugRecording.log("close requested while recording: asking to save")
            DebugRecording.answerPromptIfAsked(answerClose)
            #endif
            return false
        }
        #if DEBUG
        DebugRecording.log("window open for \(person.name); input device: \(inputName ?? "none")")
        if DebugRecording.noMicrophone {
            DebugRecording.log("-noMicrophone: not starting the microphone")
            return
        }
        let simulatedInput = DebugRecording.simulatedInput()
        #else
        let simulatedInput: [Float]? = nil
        #endif
        Task {
            if simulatedInput == nil {
                guard await AVAudioApplication.requestRecordPermission() else {
                    microphoneDenied = true
                    return
                }
            }
            #if DEBUG
            await DebugRecording.permissionDelayIfAsked()
            #endif
            // The window may have closed while the permission prompt was up:
            // never start a recording nobody can see or stop.
            guard !finished else {
                #if DEBUG
                DebugRecording.log("window closed before the microphone started: not recording")
                #endif
                return
            }
            do {
                let fileURL = try store.beginRecording(id: sessionId, person: person)
                recorder.onSamples = captioner.feed
                recorder.onSystemSleep = { stopAndSave(dueToSleep: true) }
                #if DEBUG
                recorder.simulatedInput = simulatedInput
                #endif
                try recorder.start(writingTo: fileURL)
                store.setRecordingActive(true)
                #if DEBUG
                DebugRecording.log("recording \(sessionId)\(simulatedInput == nil ? "" : " (simulated input)")")
                // Simulated runs stay offline: no caption-model download.
                if simulatedInput == nil { captioner.start() }
                #else
                captioner.start()
                #endif
            } catch {
                startError = "Could not start recording: \(error.localizedDescription)"
            }
        }
    }

    /// The "Stop and save this recording?" choice, from closing the window
    /// or quitting the app mid-recording.
    private func answerClose(_ answer: RecordingCloseAnswer) {
        confirmingClose = false
        #if DEBUG
        DebugRecording.log("prompt answered: \(answer.rawValue)")
        #endif
        switch answer {
        case .save: stopAndSave()
        case .discard: discard()
        case .keep: navigation.resolvePendingQuit(quit: false)
        }
    }

    /// ⌘Q arrived mid-recording (the app is holding the quit with
    /// `.terminateLater`): bring this window forward and ask.
    private func askBeforeQuitting() {
        guard recorder.isRecording, !saving, !finished else {
            navigation.resolvePendingQuit(quit: true)
            return
        }
        closeGuard.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        confirmingClose = true
        #if DEBUG
        DebugRecording.log("quit requested while recording: asking to save")
        DebugRecording.answerPromptIfAsked(answerClose)
        #endif
    }

    private func goOffRecord() {
        recorder.pause()
        withAnimation(.easeInOut(duration: 0.3)) { isOffRecord = true }
    }

    private func resumeRecording() {
        recorder.resume()
        // A failed resume leaves the recorder paused (with runtimeError set):
        // keep the off-record screen up rather than a live-looking one.
        guard !recorder.isPaused else { return }
        withAnimation(.easeInOut(duration: 0.3)) { isOffRecord = false }
    }

    private func discard() {
        _ = recorder.stop()
        captioner.reset()
        store.discardRecording(id: sessionId)
        #if DEBUG
        DebugRecording.log("discarded \(sessionId)")
        #endif
        close()
    }

    /// Stop & Transcribe, closing the window mid-recording, and sleep all
    /// end here. A sleep-stopped session is saved as `.recorded` and
    /// processed on wake, when the main window explains what happened.
    private func stopAndSave(dueToSleep: Bool = false) {
        guard recorder.isRecording, !saving, !finished else { return }
        saving = true
        // Duration comes from the tally: file-backed recordings don't keep
        // samples in memory, so stop() returns [] here.
        let duration = recorder.duration
        _ = recorder.stop()
        captioner.stop()
        if dueToSleep, duration < 1 {
            // Too short to process (crash recovery drops these too).
            store.discardRecording(id: sessionId)
            close()
            return
        }
        #if DEBUG
        DebugRecording.blockSaveIfAsked(store: store, sessionId: sessionId)
        #endif
        do {
            let session = try store.finishRecording(id: sessionId, duration: duration)
            #if DEBUG
            DebugRecording.log("saved \(session.id) (\(String(format: "%.1f", duration)) s)\(dueToSleep ? " on sleep" : "")")
            #endif
            if dueToSleep {
                navigation.sleepStoppedSessions.append(session.id)
                // The wake alert is shown on the main window.
                openWindow(id: LuxiconMacApp.mainWindowID)
            } else if !navigation.pendingQuit {
                // Quitting: leave it `.recorded` to transcribe next time.
                store.startProcessing(session)
            }
            close()
        } catch {
            // The audio stays on disk as an in-progress recording, and crash
            // recovery turns it into a session on next launch. `finished`
            // keeps cleanUp() from discarding it when the window closes.
            finished = true
            saving = false
            recorder.onSystemSleep = nil
            store.setRecordingActive(false)
            startError = "Could not save recording: \(error.localizedDescription) "
                + "The audio is kept and will be recovered the next time Luxicon opens."
            #if DEBUG
            DebugRecording.log("save failed (\(error.localizedDescription)); in-progress files kept for recovery")
            #endif
            // Cancel a pending quit so the error is seen; quitting again
            // goes straight through (nothing is recording any more).
            navigation.resolvePendingQuit(quit: false)
        }
    }

    private func close() {
        finished = true
        recorder.onSystemSleep = nil
        store.setRecordingActive(false)
        let window = closeGuard.window
        closeGuard.detach()
        // An open dialog (the close question, Discard's confirmation) blocks
        // closing the window, and sleep can arrive while one is up.
        confirmingClose = false
        confirmingDiscard = false
        if let window {
            for sheet in window.sheets { window.endSheet(sheet) }
        }
        dismissWindow(id: MacRecordView.windowID)
        navigation.recordingPerson = nil
        // A quit waiting on this recording can go ahead: it's saved or gone.
        navigation.resolvePendingQuit(quit: true)
        #if DEBUG
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            DebugRecording.log("record window visible after close: \(window?.isVisible ?? false)")
        }
        #endif
    }

    /// The window went away. Normally `close()` already ran; if it closed
    /// some other way, never lose audio: save a live recording, and clean
    /// up the in-progress files of one that never started.
    private func cleanUp() {
        if recorder.isRecording {
            stopAndSave()
        } else if !finished {
            store.discardRecording(id: sessionId)
            finished = true
        }
        captioner.reset()
        recorder.onSystemSleep = nil
        store.setRecordingActive(false)
        closeGuard.detach()
        if navigation.recordingPerson?.id == person.id {
            navigation.recordingPerson = nil
        }
    }
}

/// The answer to "Stop and save this recording?".
enum RecordingCloseAnswer: String {
    case save, discard, keep
}

// MARK: - Window close guard

/// Asks before the window closes, by standing in as the window's delegate
/// and forwarding everything else to SwiftUI's own delegate. SwiftUI has no
/// API to veto a window close.
@MainActor
final class WindowCloseGuard: NSObject, NSWindowDelegate {
    private(set) weak var window: NSWindow?
    // Read by the nonisolated forwarding overrides; only written on main.
    nonisolated(unsafe) private weak var original: NSWindowDelegate?
    var shouldClose: () -> Bool = { true }
    /// Detached for good: the recording is over and the window is closing.
    private var retired = false

    func attach(to window: NSWindow) {
        guard !retired, window.delegate !== self else { return }
        self.window = window
        original = window.delegate
        window.delegate = self
    }

    /// Hand the window back to SwiftUI's delegate before this goes away
    /// (the window holds its delegate weakly).
    func detach() {
        if let window, window.delegate === self {
            window.delegate = original
        }
        window = nil
        retired = true
        // Drop the closure (it captures the recording view's state).
        shouldClose = { true }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard shouldClose() else { return false }
        return original?.windowShouldClose?(sender) ?? true
    }

    override nonisolated func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override nonisolated func forwardingTarget(for aSelector: Selector!) -> Any? {
        if original?.responds(to: aSelector) == true { return original }
        return super.forwardingTarget(for: aSelector)
    }
}

/// Reports the hosting NSWindow once the view is in one.
private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> ReportingView {
        let view = ReportingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: ReportingView, context: Context) {
        nsView.onWindow = onWindow
        if let window = nsView.window { onWindow(window) }
    }

    final class ReportingView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}

/// Icon and title side by side, with the icon hidden from VoiceOver.
private struct DecorativeIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.accessibilityHidden(true)
            configuration.title
        }
    }
}
