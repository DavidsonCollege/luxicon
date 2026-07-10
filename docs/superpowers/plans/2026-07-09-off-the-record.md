# Off the Record Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an "Off the record" control to the recording screen that fully stops audio capture and transforms the screen into an unmistakable, private paused state, resumable at any time.

**Architecture:** A new user-pause API on `Recorder` tears down the audio tap and deactivates the iOS audio session (so the system mic indicator turns off) — no samples reach disk, the sample tally, or the live captioner. `RecordSheetView` gains an `isOffRecord` state that cross-fades to a new `OffRecordView` (committed deep-blue "just between us" screen). The recording Live Activity mirrors the paused state, correcting its system-rendered timer for the skipped span.

**Tech Stack:** Swift 6, SwiftUI, AVAudioEngine, ActivityKit/WidgetKit, xcodegen.

## Global Constraints

- **Xcode 26+ to build** (iOS 26 SDK, runtime-gated); deployment target **iOS 18**. Diarization needs a physical device — the Simulator can't run the capture pipeline meaningfully.
- **No app-target test bundle exists.** Per CLAUDE.md, app changes (everything in this plan lives in the app/widget targets) are verified by **building Release and observing on a physical device**, not by XCTest. Each task's "verify" steps are concrete device/build observations.
- **The `.xcodeproj` is generated — never edit it.** After adding or removing a source file, run `cd App && xcodegen generate`. `project.yml` globs the `Sources`/`Shared`/`Widgets` directories, so new files are picked up automatically once `xcodegen` runs.
- **Capture guarantee:** while off the record, **zero** samples may be written to disk, added to `sampleTally`, or passed to `onSamples`. The off-record span must not exist in the final WAV.
- **User pause outranks involuntary resume:** a phone call / route change during an off-record span must **not** silently restart capture. Only the user's Resume tap does.
- **The paused screen is committed dark** — it uses fixed deep-blue colors regardless of the system light/dark setting.
- **Copy (verbatim):** entry button "Go off the record"; eyebrow "OFF THE RECORD"; headline "This stays between you and \<name>."; subtext "No audio is being recorded or saved." + "Paused at \<mm:ss>"; resume button "Resume recording".

Reusable device build + install (referenced by "verify" steps as **[BUILD+INSTALL]**):

```bash
cd /Users/jdmills/Documents/GitHub/sitdown/App && xcodegen generate
xcodebuild -project Luxicon.xcodeproj -scheme Luxicon \
  -destination 'generic/platform=iOS' -configuration Release \
  -allowProvisioningUpdates build
# Find the device id once: xcrun devicectl list devices
xcrun devicectl device install app --device <device-id> \
  ~/Library/Developer/Xcode/DerivedData/Luxicon-*/Build/Products/Release-iphoneos/Luxicon.app
```

---

### Task 1: `Recorder` pause/resume API (the capture guarantee)

**Files:**
- Modify: `App/Sources/Recorder.swift`

**Interfaces:**
- Consumes: existing `Recorder` internals — `engine`, `startEngine()`, `setRuntimeError(_:)`, `isRecording`, `isInterrupted`, `level`, `resumeCapture()`.
- Produces:
  - `var isPaused: Bool` (get-only outside the class) — true while off the record.
  - `func pause()` — stop capturing (off the record).
  - `func resume()` — restart capturing.

- [ ] **Step 1: Add the `isPaused` flag**

In `App/Sources/Recorder.swift`, directly below the `isInterrupted` declaration (currently line 43), add:

```swift
    /// True while the user is "off the record". Capture is fully stopped and,
    /// unlike `isInterrupted`, it NEVER auto-resumes — only `resume()` restarts
    /// it. Confined to the main thread (set by `pause`/`resume`, read by the UI),
    /// like `isInterrupted`.
    private(set) var isPaused = false
```

- [ ] **Step 2: Add `pause()` and `resume()`**

In `App/Sources/Recorder.swift`, immediately after `stop()` (currently ends line 128), add:

```swift
    /// User-initiated "off the record": stop capturing entirely until `resume()`.
    /// Tears down the tap and stops the engine (so `consume` can't run — no
    /// samples are written, tallied, or fed to `onSamples`) and deactivates the
    /// audio session so the system microphone indicator turns off. Idempotent.
    func pause() {
        guard isRecording, !isPaused else { return }
        isPaused = true
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        level = 0
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// Return from "off the record" and start capturing again, rewiring the tap
    /// with the current input format (the same recovery path interruptions use).
    func resume() {
        guard isRecording, isPaused else { return }
        isPaused = false
        isInterrupted = false
        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
            #endif
            try startEngine()
        } catch {
            setRuntimeError("Couldn't resume recording: \(error.localizedDescription). Stop to save what was captured.")
        }
    }
```

- [ ] **Step 3: Make involuntary resume respect the user pause**

In `resumeCapture()` (currently line 151-162), change the guard from:

```swift
        guard isRecording, !engine.isRunning else { return }
```

to:

```swift
        // `!isPaused`: a phone call ending or a route change during an off-record
        // span must NOT silently restart capture — only the user's resume() does.
        guard isRecording, !isPaused, !engine.isRunning else { return }
```

- [ ] **Step 4: Verify it compiles**

Run:

```bash
cd /Users/jdmills/Documents/GitHub/sitdown/App && xcodegen generate && \
xcodebuild -project Luxicon.xcodeproj -scheme Luxicon \
  -destination 'generic/platform=iOS' -configuration Release \
  -allowProvisioningUpdates build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`. (Behavioral verification happens in Task 3, once the UI can drive `pause()`/`resume()`.)

- [ ] **Step 5: Commit**

```bash
git add App/Sources/Recorder.swift
git commit -m "Recorder: add user pause/resume for off-the-record"
```

---

### Task 2: `OffRecordView` — the paused screen

**Files:**
- Create: `App/Sources/Views/OffRecordView.swift`

**Interfaces:**
- Produces: `struct OffRecordView: View` with initializer `OffRecordView(personName: String, pausedAt: TimeInterval, onResume: @escaping () -> Void)`.
- Consumes: `TranscriptExport.timestamp(_:)` from LuxiconKit (already used in `RecordSheetView` line 29) for the `mm:ss` label.

- [ ] **Step 1: Create the view**

Create `App/Sources/Views/OffRecordView.swift` with exactly:

```swift
import SwiftUI
import LuxiconKit

/// Full-screen "off the record" state. Committed dark treatment (fixed colors,
/// ignores the system appearance) so the shift from the recording screen is
/// unmistakable, with 1-on-1 confidentiality imagery. Capture is already stopped
/// by the time this is shown; the only action is `onResume`.
struct OffRecordView: View {
    let personName: String
    let pausedAt: TimeInterval
    let onResume: () -> Void

    // Fixed palette — deliberately not semantic colors (see doc comment).
    private static let accent = Color(red: 0.435, green: 0.690, blue: 1.0)   // #6FB0FF
    private static let dim = Color(red: 0.239, green: 0.427, blue: 0.639)    // #3D6DA3
    private static let heading = Color(red: 0.863, green: 0.906, blue: 0.949)
    private static let subtext = Color(red: 0.498, green: 0.576, blue: 0.659)
    private static let gradientTop = Color(red: 0.063, green: 0.137, blue: 0.227) // #10233A
    private static let gradientBottom = Color(red: 0.024, green: 0.051, blue: 0.090) // #060D17
    private static let resumeFill = Color(red: 0.184, green: 0.435, blue: 0.816) // #2F6FD0

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Self.gradientTop, Self.gradientBottom],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Two figures with a lock between them.
                HStack(spacing: 10) {
                    Image(systemName: "person.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(Self.accent)
                    Image(systemName: "lock.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(Self.dim)
                    Image(systemName: "person.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(Self.accent)
                }

                Text("OFF THE RECORD")
                    .font(.caption.weight(.semibold))
                    .tracking(2)
                    .foregroundStyle(Self.accent)
                    .padding(.top, 28)

                Text("This stays between you and \(personName).")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Self.heading)
                    .padding(.top, 8)
                    .padding(.horizontal, 32)

                Text("No audio is being recorded or saved.\nPaused at \(TranscriptExport.timestamp(pausedAt))")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Self.subtext)
                    .padding(.top, 14)

                Spacer()

                Button(action: onResume) {
                    Label("Resume recording", systemImage: "record.circle")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(Self.resumeFill)
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
            }
        }
    }
}

#Preview {
    OffRecordView(personName: "Priya", pausedAt: 252, onResume: {})
}
```

- [ ] **Step 2: Regenerate the project and build**

Run:

```bash
cd /Users/jdmills/Documents/GitHub/sitdown/App && xcodegen generate && \
xcodebuild -project Luxicon.xcodeproj -scheme Luxicon \
  -destination 'generic/platform=iOS' -configuration Release \
  -allowProvisioningUpdates build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`, and `git status` shows `OffRecordView.swift` is now referenced in `App/Luxicon.xcodeproj/project.pbxproj`.

- [ ] **Step 3: Visually confirm the preview**

Open `App/Sources/Views/OffRecordView.swift` in Xcode and run the canvas `#Preview` (or do **[BUILD+INSTALL]** and view via Task 3). Expected: deep-blue screen, two blue figures flanking a lock, "OFF THE RECORD" eyebrow, headline "This stays between you and Priya.", subtext with "Paused at 04:12", and a blue "Resume recording" button pinned near the bottom.

- [ ] **Step 4: Commit**

```bash
git add App/Sources/Views/OffRecordView.swift App/Luxicon.xcodeproj/project.pbxproj
git commit -m "Add OffRecordView paused screen"
```

---

### Task 3: Wire off-record into `RecordSheetView`

**Files:**
- Modify: `App/Sources/Views/RecordSheetView.swift`

**Interfaces:**
- Consumes: `Recorder.pause()` / `Recorder.resume()` / `Recorder.isRecording` (Task 1); `OffRecordView(personName:pausedAt:onResume:)` (Task 2).
- Produces: nothing consumed by later tasks except the two call sites Task 4 hooks into (`goOffRecord()` / `resumeRecording()`).

Note: the live captioner is deliberately **not** stopped. `LiveCaptioner.start()` can't be re-called after `stop()` (its status guard), and it doesn't need to be: once `Recorder.pause()` removes the tap, `onSamples` stops firing, the caption stream idles, and captions resume on their own when `resume()` reinstalls the tap. The `OffRecordView` overlay covers the caption panel while paused.

- [ ] **Step 1: Add the off-record state flag**

In `App/Sources/Views/RecordSheetView.swift`, after `@State private var confirmingDiscard = false` (line 20), add:

```swift
    @State private var isOffRecord = false
```

- [ ] **Step 2: Add the entry button below Stop**

In `RecordSheetView`, immediately after the Stop button's closing `.padding(.horizontal)` (currently line 73), still inside the `VStack`, add:

```swift
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
```

- [ ] **Step 3: Overlay the paused screen with a cross-fade**

In `RecordSheetView`, attach an overlay to the `NavigationStack`. Change the `.onDisappear { store.setRecordingActive(false) }` line (currently line 93) so the modifiers read:

```swift
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
```

(The `NavigationStack`'s closing brace is at line 94; the `.overlay` attaches to it alongside `.onAppear`/`.onDisappear`.)

- [ ] **Step 4: Add the control methods**

In `RecordSheetView`, after `begin()` (currently ends line 150), add:

```swift
    private func goOffRecord() {
        recorder.pause()
        withAnimation(.easeInOut(duration: 0.3)) { isOffRecord = true }
    }

    private func resumeRecording() {
        recorder.resume()
        withAnimation(.easeInOut(duration: 0.3)) { isOffRecord = false }
    }
```

- [ ] **Step 5: Build, install, and verify behavior on device**

Run **[BUILD+INSTALL]** (top of plan). Then on the device, start a 1-on-1 recording and verify:

1. A "Go off the record" button sits below "Stop & Transcribe".
2. Tapping it cross-fades (~0.3s) to the deep-blue OffRecordView; the elapsed timer underneath is frozen (its value shows in "Paused at …").
3. The **system orange microphone indicator turns off** while off the record.
4. Tapping "Resume recording" cross-fades back; recording continues and the timer advances again.
5. Speak during the off-record span, resume, then Stop & Transcribe. Open the saved session: the transcript/audio contains what you said **before and after** the off-record span but **nothing** from during it, and the total duration ≈ the two active spans (the off-record time is not counted).
6. (Interruption precedence) Go off the record, trigger Siri or a quick phone call, end it: recording must **stay** paused (still on the blue screen), not silently resume.

Expected: all six hold.

- [ ] **Step 6: Commit**

```bash
git add App/Sources/Views/RecordSheetView.swift
git commit -m "RecordSheetView: off-the-record entry, overlay, and controls"
```

---

### Task 4: Mirror the paused state in the Live Activity

**Files:**
- Modify: `App/Shared/RecordingActivity.swift`
- Modify: `App/Sources/RecordingActivityController.swift`
- Modify: `App/Widgets/LuxiconWidgets.swift`
- Modify: `App/Sources/Views/RecordSheetView.swift`

**Interfaces:**
- Consumes: `goOffRecord()` / `resumeRecording()` call sites (Task 3); `RecordingActivityController.shared` (existing).
- Produces: `RecordingActivityController.setOffRecord(_ off: Bool, elapsed: TimeInterval)`; `RecordingActivityAttributes.ContentState.isOffRecord`.

- [ ] **Step 1: Add `isOffRecord` to the activity content state**

In `App/Shared/RecordingActivity.swift`, change the `ContentState` struct (currently lines 11-14) to:

```swift
    struct ContentState: Codable, Hashable {
        var startDate: Date
        var isOffRecord = false
    }
```

(The default keeps the existing `ContentState(startDate:)` call in the controller's `start()` compiling unchanged.)

- [ ] **Step 2: Add `setOffRecord` to the controller**

In `App/Sources/RecordingActivityController.swift`, after `start(personName:)` (currently ends line 25), add:

```swift
    /// Update the running activity to show / clear the off-record state. On
    /// resume, `elapsed` is the true active duration; the start date is shifted
    /// to `now - elapsed` so the system-rendered timer resumes at the right
    /// value instead of counting the off-record gap.
    func setOffRecord(_ off: Bool, elapsed: TimeInterval) {
        guard let id = activityId else { return }
        let startDate = Date().addingTimeInterval(-elapsed)
        let state = RecordingActivityAttributes.ContentState(startDate: startDate, isOffRecord: off)
        Task.detached {
            for activity in Activity<RecordingActivityAttributes>.activities where activity.id == id {
                await activity.update(.init(state: state, staleDate: nil))
            }
        }
    }
```

- [ ] **Step 3: Render the off-record state in the widget**

In `App/Widgets/LuxiconWidgets.swift`, the lock-screen/banner view is the `HStack` at lines 19-38 and the timer `Text` appears there and in the Dynamic Island (lines 33, 47, 62). Replace the trailing timer in the **lock-screen `HStack`** (lines 33-36) with a state-aware view:

```swift
                if context.state.isOffRecord {
                    Label("Off the record", systemImage: "lock.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Text(timerInterval: timerRange(context), countsDown: false)
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .frame(maxWidth: 70)
                }
```

And change the leading `Image(systemName: "record.circle")` (lines 20-22) to reflect the pause:

```swift
                Image(systemName: context.state.isOffRecord ? "pause.circle.fill" : "record.circle")
                    .font(.title2)
                    .foregroundStyle(context.state.isOffRecord ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
```

For the **Dynamic Island** trailing region (lines 46-51), replace the `Text(timerInterval:…)` with:

```swift
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.isOffRecord {
                        Image(systemName: "lock.fill").foregroundStyle(.secondary)
                    } else {
                        Text(timerInterval: timerRange(context), countsDown: false)
                            .monospacedDigit()
                            .font(.callout.weight(.semibold))
                            .frame(maxWidth: 60)
                    }
                }
```

For the **compactTrailing** (lines 61-64), replace with:

```swift
            } compactTrailing: {
                if context.state.isOffRecord {
                    Image(systemName: "lock.fill")
                } else {
                    Text(timerInterval: timerRange(context), countsDown: false)
                        .monospacedDigit()
                        .frame(maxWidth: 48)
                }
```

(Leave the `.leading`/`.bottom` expanded regions, `compactLeading`, and `minimal` as they are.)

- [ ] **Step 4: Call `setOffRecord` from the view**

In `App/Sources/Views/RecordSheetView.swift`, update the two methods added in Task 3 so each mirrors to the Live Activity:

```swift
    private func goOffRecord() {
        recorder.pause()
        RecordingActivityController.shared.setOffRecord(true, elapsed: recorder.duration)
        withAnimation(.easeInOut(duration: 0.3)) { isOffRecord = true }
    }

    private func resumeRecording() {
        recorder.resume()
        RecordingActivityController.shared.setOffRecord(false, elapsed: recorder.duration)
        withAnimation(.easeInOut(duration: 0.3)) { isOffRecord = false }
    }
```

- [ ] **Step 5: Build, install, and verify on device**

Run **[BUILD+INSTALL]**. Then start a recording and verify:

1. Go off the record: the lock-screen Live Activity and Dynamic Island switch from the running timer to a lock / "Off the record" indicator, and the leading glyph changes from a red record dot to a pause symbol.
2. Resume: the timer returns and continues at roughly the correct elapsed value (it does **not** jump forward by the off-record duration).

Expected: both hold. (If Live Activities are disabled on the device, the app still works — `setOffRecord` no-ops when there's no activity; confirm the in-app flow from Task 3 is unaffected.)

- [ ] **Step 6: Commit**

```bash
git add App/Shared/RecordingActivity.swift App/Sources/RecordingActivityController.swift \
  App/Widgets/LuxiconWidgets.swift App/Sources/Views/RecordSheetView.swift
git commit -m "Live Activity: reflect off-the-record paused state"
```

---

## Notes for the implementer

- Work the tasks in order — Task 3 depends on Tasks 1 and 2; Task 4 depends on Task 3.
- If `xcodebuild` can't resolve a device/provisioning automatically, the plan's `-allowProvisioningUpdates` plus the `DEVELOPMENT_TEAM` in `project.yml` should suffice; otherwise open the generated project once in Xcode to let it settle signing.
- Do not add network calls, change the sync protocol, or alter `Store` persistence — a session that used off-record is an ordinary session (README privacy posture is load-bearing App Store copy).
