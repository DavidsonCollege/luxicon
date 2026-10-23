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

/// One recording with one person, on the microphone picked in the window
/// (remembered; the system default until one is picked).
///
/// Mirrors the iPhone's record sheet: audio streams to disk as it's captured
/// (a crash is recovered into a session on next launch), live captions are a
/// best-effort preview, and Stop & Transcribe starts the full pipeline. If
/// the Mac goes to sleep, the recording stops and is saved; processing
/// starts on wake (`MacNavigation.handleWake`). Muting the mic (AirPods
/// stem, a USB mic's mute button) takes the recording off the record until
/// it's unmuted (`RecordingInputController`).
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
    @State private var input = RecordingInputController()
    @State private var startError: String?
    @State private var microphoneDenied = false
    @State private var began = false
    @State private var saving = false
    /// Saved or discarded: the window is on its way out.
    @State private var finished = false
    @State private var confirmingDiscard = false
    @State private var confirmingClose = false

    private var isOffRecord: Bool { input.isOffRecord }

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
                // VoiceOver shouldn't reach it behind the overlay either
                // (each element below is hidden the same way).
                .accessibilityHidden(isOffRecord)

                captionPanel
                    .accessibilityHidden(isOffRecord)

                VStack(spacing: 6) {
                    // Its own view, so the timeline's ticks don't rebuild
                    // the menu.
                    InputPickerRow(input: input)
                    // Decorative icons: VoiceOver reads just the text (the
                    // hand symbol would otherwise be announced as "Block").
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
                // Not `.accessibilityHidden(isOffRecord)`: hidden(false) on
                // the container would re-expose the decorative icons inside.
                .accessibilityHiddenWhen(isOffRecord)

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
            ZStack {
                if isOffRecord {
                    OffRecordView(personName: person.name, pausedAt: recorder.duration,
                                  isMuted: input.offRecord.mode == .offRecord(reason: .muted),
                                  onUnmute: input.isSystemMuted ? { input.unmuteSystem() } : nil,
                                  onResume: resumeRecording)
                        .transition(.opacity)
                }
            }
            // Mute and unmute arrive outside any user action: animate on
            // the state itself, whatever changed it.
            .animation(.easeInOut(duration: 0.3), value: isOffRecord)
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
            // The captured device can change under us (the default changes,
            // Core Audio reroutes); the picker shows the real one.
            while !Task.isCancelled {
                input.refresh()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        #if DEBUG
        .task { await DebugRecording.runHooks(recorder: recorder, closeGuard: closeGuard, stop: { stopAndSave() }) }
        .task { await DebugRecording.runInputHooks(input: input, recorder: recorder) }
        #endif
    }

    /// Off the record, the stop button is covered, and its shortcut (⌘.)
    /// must not reach it either. (No bare-key shortcut: a stray Space must
    /// never end a live recording.)
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
        input.prepare()
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
        DebugRecording.log("window open for \(person.name); input device: \(input.currentDevice?.name ?? "none")")
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
                // Starts off the record if the mic is already muted.
                try input.start(recorder: recorder, writingTo: fileURL)
                store.setRecordingActive(true)
                #if DEBUG
                DebugRecording.log("recording \(sessionId)\(simulatedInput == nil ? "" : " (simulated input)")")
                // Simulated runs stay offline: no caption-model download.
                if simulatedInput == nil {
                    captioner.start()
                } else if let captions = DebugRecording.simulatedCaptions() {
                    captioner.debugPlay(captions)
                }
                #else
                captioner.start()
                #endif
            } catch {
                input.stop()
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
        input.goOffRecord()
    }

    /// A failed resume leaves the recorder paused (with runtimeError set),
    /// and the off-record screen stays up rather than a live-looking one.
    private func resumeRecording() {
        input.resume()
    }

    private func discard() {
        input.stop()
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
        input.stop()
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
        input.stop()
        recorder.onSystemSleep = nil
        store.setRecordingActive(false)
        closeGuard.detach()
        if navigation.recordingPerson?.id == person.id {
            navigation.recordingPerson = nil
        }
    }
}

/// "Input: [Microphone ▾]", plus a one-line note when the saved or captured
/// microphone went missing.
private struct InputPickerRow: View {
    let input: RecordingInputController

    var body: some View {
        VStack(spacing: 4) {
            if input.deviceList.devices.isEmpty {
                Label("Input: No input device", systemImage: "mic")
                    .labelStyle(DecorativeIconLabelStyle())
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "mic").accessibilityHidden(true)
                    Text("Input:").accessibilityHidden(true)
                    Picker("Microphone", selection: selection) {
                        if input.currentDevice == nil {
                            Text("Choose a Microphone").tag(input.currentDeviceID ?? 0)
                        }
                        ForEach(input.deviceList.devices) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .help("The microphone this recording captures from. Switching keeps recording.")
                }
            }
            if let note = input.deviceNote {
                Label(note, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .labelStyle(DecorativeIconLabelStyle())
            }
        }
        .font(.callout)
    }

    private var selection: Binding<AudioDeviceID> {
        Binding(
            get: { input.currentDeviceID ?? 0 },
            set: { id in
                if let device = input.deviceList.device(id: id) { input.select(device) }
            })
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

private extension View {
    /// Hidden from VoiceOver while `hidden`; otherwise untouched, so the
    /// children's own `accessibilityHidden(true)` still applies.
    @ViewBuilder
    func accessibilityHiddenWhen(_ hidden: Bool) -> some View {
        if hidden {
            accessibilityHidden(true)
        } else {
            self
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
