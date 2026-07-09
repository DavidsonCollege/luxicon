# Mac Sync Per-Session Status Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record every iPhone→Mac push outcome on the session and surface it in the UI (row icons + a diagnostic "Mac Sync" section with retry), visible only when Mac Sync is enabled.

**Architecture:** `SessionRecord` gains `lastPushDate`/`lastPushError`; `Store.pushToMac` becomes the single recording point for outcomes, so auto-push, "Push All to Mac", foreground auto-retry, and manual retry all feed the same state. UI derives a three-way state (synced/failed/pending) and renders it in `SessionRow` and a new session-detail section.

**Tech Stack:** Swift 6 / SwiftUI, `@Observable` Store (MainActor), xcodegen-generated Xcode project.

**Spec:** `docs/superpowers/specs/2026-07-09-mac-sync-status-design.md`

## Global Constraints

- "Mac Sync enabled" is exactly `!store.syncToken.isEmpty` — the same gate used by existing settings rows and the "Push All to Mac" menu item.
- Sync state renders only for sessions with `status == .ready`.
- The app target has **no unit-test bundle** (Tests/ covers LuxiconKit only, and no LuxiconKit code changes here). Verification per task is a clean Release build; final task verifies on-device.
- All modified files already exist, so **`xcodegen generate` is NOT needed** (only new files require it).
- Build command (run from `App/`):
  `xcodebuild -project Luxicon.xcodeproj -scheme Luxicon -destination 'generic/platform=iOS' -configuration Release -allowProvisioningUpdates build`
  Expected: `** BUILD SUCCEEDED **`
- Commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Persist push outcomes on SessionRecord

**Files:**
- Modify: `App/Sources/Store.swift` (SessionRecord struct, ~line 14-34)
- Modify: `App/Sources/MacSyncService.swift`

**Interfaces:**
- Consumes: existing `Store.PushOutcome` enum, `LuxiconSync.push`.
- Produces: `SessionRecord.lastPushDate: Date?`, `SessionRecord.lastPushError: String?`, `SessionRecord.macSyncState: MacSyncState` where `enum MacSyncState: Equatable { case synced(Date); case failed(String); case pending }`. Later tasks (3, 4) render from `macSyncState`.

- [ ] **Step 1: Add the two fields to SessionRecord**

In `App/Sources/Store.swift`, inside `struct SessionRecord`, after `var errorMessage: String?`:

```swift
    /// Mac Sync: when this session last pushed successfully, and the error
    /// message from the last failed attempt (nil after a success). Optionals
    /// so pre-existing store.json decodes unchanged.
    var lastPushDate: Date?
    var lastPushError: String?
```

(Synthesized Codable decodes missing optional keys as `nil`, so no migration code. `SessionRecord` is persisted inside `Persisted.sessions`, which round-trips the whole struct — no `Persisted` change needed.)

- [ ] **Step 2: Derive the UI state and record outcomes in pushToMac**

In `App/Sources/MacSyncService.swift`, add above the `extension Store`:

```swift
/// Three-way sync state for the UI. Meaningful only while Mac Sync is
/// enabled (`!syncToken.isEmpty`) and the session is `.ready`.
enum MacSyncState: Equatable {
    case synced(Date)
    case failed(String)
    case pending
}

extension SessionRecord {
    var macSyncState: MacSyncState {
        if let error = lastPushError { return .failed(error) }
        if let date = lastPushDate { return .synced(date) }
        return .pending
    }
}
```

Replace the body of `pushToMac` so both branches funnel through a recording helper (keep the doc comment):

```swift
    /// Push one session's export envelope (transcript + summary).
    @discardableResult
    func pushToMac(_ session: SessionRecord) async -> PushOutcome {
        let token = syncToken.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty, let transcript = session.transcript else {
            return .notConfigured
        }
        let outcome: PushOutcome
        do {
            let payload = try TranscriptExport.json(transcript, summary: session.summary)
            let person = person(id: session.personId)?.name ?? "session"
            let filename = "\(person) \(session.date.formatted(.iso8601.year().month().day())) \(session.id.uuidString.prefix(8)).json"
            let host = syncHost.trimmingCharacters(in: .whitespaces)
            try await LuxiconSync.push(
                filename: filename,
                payload: payload,
                token: token,
                host: host.isEmpty ? nil : host
            )
            outcome = .success
        } catch {
            outcome = .failure((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        recordPushOutcome(outcome, for: session.id)
        return outcome
    }

    /// Write the outcome onto the stored session (looked up by id — the
    /// parameter is a value copy, and the session may have been deleted
    /// mid-push).
    private func recordPushOutcome(_ outcome: PushOutcome, for id: UUID) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        switch outcome {
        case .success:
            sessions[i].lastPushDate = Date()
            sessions[i].lastPushError = nil
        case .failure(let message):
            sessions[i].lastPushError = message
        case .notConfigured:
            return
        }
        save()
    }
```

- [ ] **Step 3: Build**

Run from `App/`:
```bash
xcodebuild -project Luxicon.xcodeproj -scheme Luxicon -destination 'generic/platform=iOS' -configuration Release -allowProvisioningUpdates build
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add App/Sources/Store.swift App/Sources/MacSyncService.swift
git commit -m "feat: record Mac push outcomes on each session

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Auto-retry failed pushes on foreground

**Files:**
- Modify: `App/Sources/Store.swift` (add cooldown property near `vocabularyLastSyncAttempt`, ~line 68)
- Modify: `App/Sources/MacSyncService.swift`
- Modify: `App/Sources/LuxiconApp.swift:21`

**Interfaces:**
- Consumes: `pushToMac(_:)` and `SessionRecord.lastPushError` from Task 1.
- Produces: `Store.retryFailedPushesIfEnabled()` (no arguments, sync, fires a Task).

- [ ] **Step 1: Add the cooldown timestamp to Store**

In `App/Sources/Store.swift`, directly after the `@ObservationIgnored var vocabularyLastSyncAttempt: Date?` line:

```swift
    /// Rate limit for the foreground failed-push retry sweep.
    @ObservationIgnored var lastPushRetrySweep: Date?
```

- [ ] **Step 2: Add the retry sweep to MacSyncService**

In `App/Sources/MacSyncService.swift`, inside `extension Store`, after `autoPushIfEnabled`:

```swift
    /// Foreground trigger: retry sessions whose last push failed. Only
    /// attempted-and-failed sessions retry — never-pushed ones don't, so
    /// enabling sync can't surprise-upload the whole history ("Push All to
    /// Mac" is the deliberate backfill). Rate-limited like vocabulary sync.
    func retryFailedPushesIfEnabled() {
        guard autoPushToMac, !syncToken.isEmpty else { return }
        if let last = lastPushRetrySweep,
           Date().timeIntervalSince(last) < 60 { return }
        let failed = sessions.filter { $0.status == .ready && $0.lastPushError != nil }
        guard !failed.isEmpty else { return }
        lastPushRetrySweep = Date()
        Task {
            for session in failed { await pushToMac(session) }
        }
    }
```

- [ ] **Step 3: Call it on scene activation**

In `App/Sources/LuxiconApp.swift`, in the `case .active:` branch, after `store.syncVocabularyIfConfigured()`:

```swift
                store.retryFailedPushesIfEnabled()
```

- [ ] **Step 4: Build**

Run from `App/`:
```bash
xcodebuild -project Luxicon.xcodeproj -scheme Luxicon -destination 'generic/platform=iOS' -configuration Release -allowProvisioningUpdates build
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add App/Sources/Store.swift App/Sources/MacSyncService.swift App/Sources/LuxiconApp.swift
git commit -m "feat: retry failed Mac pushes when the app foregrounds

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Sync indicator on session rows

**Files:**
- Modify: `App/Sources/Views/PersonDetailView.swift` (`SessionRow`, ~line 141-172)

**Interfaces:**
- Consumes: `SessionRecord.macSyncState` (Task 1), `store.syncToken`.
- Produces: visual only.

- [ ] **Step 1: Add the indicator next to the status mark**

In `SessionRow`'s `body`, replace the `case .ready:` branch of the status `switch`:

```swift
            case .ready:
                if !store.syncToken.isEmpty {
                    syncBadge
                }
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
```

And add to `SessionRow`, below `body`:

```swift
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
```

- [ ] **Step 2: Build**

Run from `App/`:
```bash
xcodebuild -project Luxicon.xcodeproj -scheme Luxicon -destination 'generic/platform=iOS' -configuration Release -allowProvisioningUpdates build
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add App/Sources/Views/PersonDetailView.swift
git commit -m "feat: show Mac Sync state on session rows

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Mac Sync section in session detail

**Files:**
- Modify: `App/Sources/Views/SessionDetailView.swift` (`TranscriptView`, ~line 66-199)

**Interfaces:**
- Consumes: `SessionRecord.macSyncState` (Task 1), `store.pushToMac(_:)`, `store.syncToken`.
- Produces: visual only.

- [ ] **Step 1: Add push-in-flight state**

In `TranscriptView`, after `@State private var summaryURL: URL?`:

```swift
    @State private var isPushing = false
```

- [ ] **Step 2: Add the section to the List**

In `TranscriptView.body`, directly after `summarySection`:

```swift
            macSyncSection
```

- [ ] **Step 3: Implement the section**

In `TranscriptView`, after the `summarySection` property:

```swift
    /// Push status + diagnostics; rendered only while Mac Sync is enabled.
    /// TranscriptView re-inits with the updated record after each push, so
    /// the section always reflects the last recorded outcome.
    @ViewBuilder
    private var macSyncSection: some View {
        if !store.syncToken.isEmpty {
            Section("Mac Sync") {
                switch session.macSyncState {
                case .synced(let date):
                    Label {
                        Text("Pushed to Mac \(date.formatted(.relative(presentation: .named)))")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                case .failed(let message):
                    Label {
                        Text(message).foregroundStyle(.red)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    pushButton("Retry Push")
                case .pending:
                    Label {
                        Text("Not pushed yet").foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "laptopcomputer")
                            .foregroundStyle(.secondary)
                    }
                    pushButton("Push to Mac")
                }
            }
        }
    }

    private func pushButton(_ title: String) -> some View {
        Button {
            isPushing = true
            Task {
                await store.pushToMac(session)
                isPushing = false
            }
        } label: {
            if isPushing {
                HStack {
                    ProgressView()
                    Text("Pushing…").padding(.leading, 8)
                }
            } else {
                Label(title, systemImage: "laptopcomputer.and.arrow.down")
            }
        }
        .disabled(isPushing)
    }
```

- [ ] **Step 4: Build**

Run from `App/`:
```bash
xcodebuild -project Luxicon.xcodeproj -scheme Luxicon -destination 'generic/platform=iOS' -configuration Release -allowProvisioningUpdates build
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add App/Sources/Views/SessionDetailView.swift
git commit -m "feat: Mac Sync diagnostics and retry in session detail

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: On-device verification

**Files:** none (verification only).

**Interfaces:**
- Consumes: the installed app, JD's iPhone 15 Pro (device ID `83AFDE30-19F5-5A26-B982-E27D48D3E108`), a Mac terminal for `luxicon-mcp listen`.

- [ ] **Step 1: Install the Release build**

```bash
xcrun devicectl device install app --device 83AFDE30-19F5-5A26-B982-E27D48D3E108 ~/Library/Developer/Xcode/DerivedData/Luxicon-*/Build/Products/Release-iphoneos/Luxicon.app
```
Expected: `App installed:` with the bundle id `edu.davidson.luxicon`. If the device shows unavailable, ask JD to unlock/plug in the phone.

- [ ] **Step 2: Manual checks (needs JD or the phone in hand)**

1. With Mac Sync configured and `luxicon-mcp listen` running: open a ready session → Mac Sync section shows "Not pushed yet" → tap **Push to Mac** → section flips to "Pushed to Mac now"; row shows a small green laptop.
2. Stop the listener → **Retry Push** on another session → section shows the red error text ("No Mac listener found…" or connection error); row shows the orange badged laptop.
3. Restart the listener, background the app for >60s, foreground it (with "Push automatically" on) → failed session flips to synced without any taps.
4. Clear the pairing token in My Voice → all sync icons and the Mac Sync section disappear.

- [ ] **Step 3: Report results to JD** — including any check that could not be run without the physical device, stated plainly.
