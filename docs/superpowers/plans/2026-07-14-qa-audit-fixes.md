# QA Audit Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the 2026-07-14 QA audit findings in the approved priority order: ship `listener-v1.0.1`, close the two silent-data-loss paths, budget-check the summarizer prompts, refresh stale user-facing copy, and sweep dead code plus compiler warnings.

**Architecture:** One urgent release (Task 1) cut from current `main` — no code change needed, the drift fix is already merged. All code fixes land on a new branch `qa/audit-fixes` off `main`, one commit per task, PR at the end. Kit changes are TDD (swift-testing, offline); App changes are verified by `xcodebuild` (no app test target exists, per CLAUDE.md).

**Tech Stack:** Swift 6 package (swift-testing), SwiftUI iOS app (xcodegen), GitHub Actions tag-driven listener release.

## Global Constraints

- `Store.Persisted` / `SessionRecord` back-compat: never rename/repurpose persisted keys; new fields optional-or-defaulted (CLAUDE.md).
- Tests stay offline — no model downloads.
- `cd App && xcodegen generate` is required only if project.yml or the file set changes (none of these tasks adds/removes App source files).
- Never write credential values into the repo (docs/releasing.md).
- README privacy posture is load-bearing App Store copy — edits must keep the "everything on-device; only opt-in network features" story intact.
- Wire-protocol files (`LuxiconSync`, `SyncPusher`, `SyncListener`) are NOT touched by any task here (TranscriptLibrary is the Mac-side reader, not the wire).

---

### Task 1: Cut `listener-v1.0.1` from current main

The released v1.0.0 listener requires `SessionSummary.headline`, which commit 6618b0a removed; every summarized session pushed by the current app is invisible to its MCP library scan. Current `main` already decodes correctly — releasing it IS the fix.

**Files:** none (tag + CI only)

**Interfaces:**
- Produces: GitHub Release `listener-v1.0.1` with a notarized pkg.

- [ ] **Step 1: Confirm main is current and clean**

Run: `git checkout main && git pull && git status`
Expected: `Your branch is up to date with 'origin/main'`, clean tree.

- [ ] **Step 2: Tag and push**

```bash
git tag listener-v1.0.1 && git push origin listener-v1.0.1
```

- [ ] **Step 3: Watch CI (release-listener workflow, macos-26 runner: build, sign, notarize, staple, publish)**

Run: `gh run watch $(gh run list --workflow release-listener --limit 1 --json databaseId --jq '.[0].databaseId')`
Expected: success; then `gh release view listener-v1.0.1` shows `LuxiconListener-1.0.1.pkg`.
If the workflow fails for a workflow-definition reason, fix and move the tag: `git tag -d TAG && git push origin :refs/tags/TAG && git tag TAG && git push origin TAG` (docs/releasing.md).

- [ ] **Step 4: Create the working branch for the remaining tasks**

```bash
git checkout -b qa/audit-fixes
```

---

### Task 2: TranscriptLibrary — a malformed summary must not hide the session

Prevents recurrence of the Task 1 bug class: today, a `summary` key whose object doesn't match the reader's schema fails the whole `SessionEnvelope` decode, the `try?`-chain falls through, and the session vanishes from the library. Decode the summary leniently — the transcript is the payload; the summary is an enrichment.

**Files:**
- Modify: `Sources/LuxiconKit/TranscriptLibrary.swift:56-60`
- Test: `Tests/LuxiconKitTests/TranscriptLibraryTests.swift`

**Interfaces:**
- Consumes: `TranscriptLibrary.parse(_:sourceFile:folderName:)` (internal, existing).
- Produces: unchanged public API; `Session.summary` is `nil` when the stored summary doesn't decode.

- [ ] **Step 1: Write the failing test** (append inside `@Suite struct TranscriptLibraryTests`)

```swift
    @Test func summaryWithUnknownShapeDoesNotHideTheSession() {
        // A schema drift in SessionSummary (v1.0.0 shipped with a required
        // `headline`; 6618b0a removed it) must degrade to summary-less, never
        // to the session disappearing from every MCP tool.
        struct AlienSummary: Encodable { let headline = "Topics" }  // no overview/generatedAt
        struct Envelope: Encodable {
            let schemaVersion = 1, kind = "one-on-one"
            let transcript: MeetingTranscript
            let summary: AlienSummary
        }
        let data = encode(Envelope(transcript: transcript(title: "1-on-1 with Sam Rivera", day: 0)))
        let sessions = TranscriptLibrary.parse(data, sourceFile: "d.json", folderName: nil)
        #expect(sessions.count == 1)
        #expect(sessions[0].summary == nil)
        #expect(sessions[0].person == "Sam Rivera")
    }
```

- [ ] **Step 2: Run it, verify it fails**

Run: `swift test --filter TranscriptLibraryTests`
Expected: FAIL — `sessions.count == 1` is false (parse returns `[]`).

- [ ] **Step 3: Make `SessionEnvelope.summary` decode leniently**

Replace the `SessionEnvelope` struct in `parse` with:

```swift
        struct SessionEnvelope: Decodable {
            let kind: String?
            let transcript: MeetingTranscript
            let summary: SessionSummary?

            enum CodingKeys: String, CodingKey { case kind, transcript, summary }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                kind = try c.decodeIfPresent(String.self, forKey: .kind)
                transcript = try c.decode(MeetingTranscript.self, forKey: .transcript)
                // Lenient: a summary from a different app version (schema
                // drift) degrades to nil instead of hiding the whole session.
                summary = try? c.decodeIfPresent(SessionSummary.self, forKey: .summary)
            }
        }
```

- [ ] **Step 4: Run the suite**

Run: `swift test --filter TranscriptLibraryTests`
Expected: PASS (all tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LuxiconKit/TranscriptLibrary.swift Tests/LuxiconKitTests/TranscriptLibraryTests.swift
git commit -m "Kit: library scan tolerates summary schema drift instead of hiding the session"
```

---

### Task 3: Pipeline — an all-empty transcription run fails the session

Today every appleSpeech runtime failure maps to an empty turn, and a run where *every* turn came back empty lands `.ready` with zero turns — a lost meeting behind a green status. Fail the run instead when there was real speech to transcribe. Check lives in a static internal helper (the codebase's established unit-testable pattern) called from `process()`.

**Files:**
- Modify: `Sources/LuxiconKit/MeetingPipeline.swift` (new error + static check + call in `process`)
- Test: `Tests/LuxiconKitTests/PipelineLogicTests.swift`

**Interfaces:**
- Produces: `public struct TranscriptionEmptyError: Error, LocalizedError`; `static func checkTranscriptionYield(turns: [TranscriptTurn], spans: [TurnSpan]) throws` (internal). App side needs NO change: `SessionProcessing`'s generic `catch` already sets `.failed` + `errorMessage`, and the existing Retry button covers recovery.

- [ ] **Step 1: Write the failing tests** (append to `PipelineLogicTests.swift`, top level)

```swift
@Suite struct TranscriptionYieldTests {
    private func span(_ start: Double, _ end: Double) -> MeetingPipeline.TurnSpan {
        MeetingPipeline.TurnSpan(speakerId: 0, start: start, end: end)
    }

    @Test func allTurnsEmptyOnRealSpeechThrows() {
        // 3 diarized turns, 30 s of speech, zero transcribed text: the
        // engine broke at runtime (e.g. appleSpeech asset evicted) — that
        // must surface as a failure, not a .ready empty transcript.
        #expect(throws: TranscriptionEmptyError.self) {
            try MeetingPipeline.checkTranscriptionYield(
                turns: [], spans: [span(0, 10), span(10, 20), span(20, 30)])
        }
    }

    @Test func shortRecordingsMayLegitimatelyYieldNothing() throws {
        // A cough or mic test: diarization finds a blip, ASR rightly hears
        // no words. Below the speech threshold the empty result stands.
        try MeetingPipeline.checkTranscriptionYield(turns: [], spans: [span(0, 4)])
    }

    @Test func anyTranscribedTurnPasses() throws {
        let turn = TranscriptTurn(id: 0, speakerId: 0, start: 0, end: 30, text: "hello")
        try MeetingPipeline.checkTranscriptionYield(
            turns: [turn], spans: [span(0, 30), span(30, 60)])
    }

    @Test func noSpansPasses() throws {
        try MeetingPipeline.checkTranscriptionYield(turns: [], spans: [])
    }
}
```

- [ ] **Step 2: Run, verify failure**

Run: `swift test --filter TranscriptionYieldTests`
Expected: FAIL to compile (`TranscriptionEmptyError` / `checkTranscriptionYield` undefined).

- [ ] **Step 3: Implement**

In `MeetingPipeline.swift`, below `EngineUnavailableError` (line ~61), add:

```swift
/// The engine ran but produced no text for any speaker turn on a recording
/// with real speech — an engine runtime failure (e.g. the system speech
/// asset became unavailable mid-run), not a quiet meeting. Surfaced instead
/// of a "ready" empty transcript, which reads as a silently lost meeting.
public struct TranscriptionEmptyError: Error, LocalizedError {
    public let turnCount: Int
    public init(turnCount: Int) { self.turnCount = turnCount }
    public var errorDescription: String? {
        "Transcription produced no text for any of the \(turnCount) speaker "
            + "turns. The speech engine may be unavailable — try again, or "
            + "choose a different transcription engine in Settings."
    }
}
```

In the `// MARK: - Steps (internal, unit-testable)` section add:

```swift
    /// Below this much total diarized speech, an all-empty ASR result is
    /// plausible (mic test, cough) and the empty transcript stands.
    static let minSpeechSecondsToDemandText: Double = 10

    /// Guard against a silently broken engine: real speech in, zero text out
    /// across every turn is a failure, not an empty meeting.
    static func checkTranscriptionYield(turns: [TranscriptTurn], spans: [TurnSpan]) throws {
        guard turns.isEmpty, !spans.isEmpty else { return }
        let speech = spans.reduce(0) { $0 + ($1.end - $1.start) }
        if speech >= minSpeechSecondsToDemandText {
            throw TranscriptionEmptyError(turnCount: spans.count)
        }
    }
```

In `process()`, after the turn loop (after line 211's closing `}`) and before `// 5. Name speakers`:

```swift
        try Self.checkTranscriptionYield(turns: turns, spans: turnSpans)
```

- [ ] **Step 4: Run the full Kit suite**

Run: `swift test`
Expected: PASS, 121 + 4 new tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/LuxiconKit/MeetingPipeline.swift Tests/LuxiconKitTests/PipelineLogicTests.swift
git commit -m "Kit: all-empty transcription on real speech fails the run instead of landing a ready empty transcript"
```

---

### Task 4: App — auto-push still fires when the summary pass fails or is cancelled

`startProcessing` routes a finished transcript to `startSummarizing` ("auto-push fires after the summary lands"), but only the success branch pushes. A guardrail decline or backgrounding leaves the session `.pending` with `lastPushDate`/`lastPushError` both nil — invisible to the retry sweep, never reaching the Mac.

**Files:**
- Modify: `App/Sources/SummaryService.swift:139-147` (the two catch branches in `startSummarizing`)

**Interfaces:**
- Consumes: `Store.autoPushIfEnabled(_ session: SessionRecord)` (`App/Sources/MacSyncService.swift:86` — no-ops unless auto-push is on and a token exists).

- [ ] **Step 1: Edit the catch branches**

Replace:

```swift
            } catch is CancellationError {
                // Backgrounded: leave the session summary-less; the Generate
                // Summary button remains available.
            } catch {
                // Real failures get a visible reason next to the Generate
                // button (guardrail refusals especially must not look like
                // the app silently doing nothing).
                processing.summarizeError[sessionId] = Self.summarizeErrorMessage(error)
            }
```

with:

```swift
            } catch is CancellationError {
                // Backgrounded: leave the session summary-less; the Generate
                // Summary button remains available. The finished transcript
                // still auto-pushes — the summary was the add-on, not the
                // payload, and the Mac must not silently miss a session.
                if let s = self.sessions.first(where: { $0.id == sessionId }) {
                    self.autoPushIfEnabled(s)
                }
            } catch {
                // Real failures get a visible reason next to the Generate
                // button (guardrail refusals especially must not look like
                // the app silently doing nothing). The transcript still
                // auto-pushes despite the failed summary.
                processing.summarizeError[sessionId] = Self.summarizeErrorMessage(error)
                if let s = self.sessions.first(where: { $0.id == sessionId }) {
                    self.autoPushIfEnabled(s)
                }
            }
```

- [ ] **Step 2: Build the app**

Run: `cd App && xcodebuild -project Luxicon.xcodeproj -scheme Luxicon -destination 'generic/platform=iOS' -configuration Release -allowProvisioningUpdates build 2>&1 | grep -E 'error:|BUILD'`
Expected: `** BUILD SUCCEEDED **`, no errors.

- [ ] **Step 3: Commit**

```bash
git add App/Sources/SummaryService.swift
git commit -m "App: auto-push the transcript even when the summary pass fails or is cancelled"
```

---

### Task 5: Summarizer — every prompt respects the instance budget

Three related sizing bugs: (a) the fits-in-one-pass check ignores reference/metadata overhead (rich participant contexts can blow a 4,096-token window); (b) the single-pass clip uses the hardcoded 20,000 default instead of `transcriptCharBudget` (silently middle-cuts on 8k-token devices); (c) the merge prompt concatenates up to 2,000 chars per section note with no total check (long meetings on 4k-token phones fail every summary attempt), and a single over-budget monologue chunk is fed unclipped into its section prompt.

Fix: compute an overhead-adjusted `available` budget once in `summarize`, thread it through the single-pass clip, the section split/clip, and a per-note allowance derived from the chunk count so the assembled merge prompt always fits.

**Files:**
- Modify: `Sources/LuxiconKit/MeetingSummarizer.swift` (`summarize`, `summarizeInSections`, `userPrompt`, `sectionNotesPrompt`)
- Test: `Tests/LuxiconKitTests/SummarizerTests.swift`

**Interfaces:**
- Produces (internal, tests use them): `userPrompt(for:context:clipLimit:)` (new param, default 20_000 keeps old call sites valid), `sectionNotesPrompt(part:of:turns:clipLimit:)` (new param), `summarizeInSections(_:context:budget:)` (new param). `MergeProseAllowance` stays a private detail. Public API unchanged.

- [ ] **Step 1: Write the failing tests** (append as a new suite in `SummarizerTests.swift`)

```swift
@Suite struct SummarizerBudgetTests {
    private func turns(count: Int, chars: Int) -> [TranscriptTurn] {
        (0..<count).map {
            TranscriptTurn(id: $0, speakerId: $0 % 2, speakerName: $0 % 2 == 0 ? "JD" : "Sam",
                           start: Double($0), end: Double($0 + 1),
                           text: String(repeating: "w", count: chars))
        }
    }
    private func transcript(_ turns: [TranscriptTurn]) -> MeetingTranscript {
        MeetingTranscript(title: "Weekly 1:1",
                          date: Date(timeIntervalSince1970: 1_780_000_000),
                          duration: 60, turns: turns)
    }
    private func userText(_ call: [ChatMessage]) -> String {
        call.last { $0.role == .user }?.content ?? ""
    }

    @Test func singlePassClipHonorsTheInstanceBudget() async throws {
        // Budget 30k, transcript ~25k: fits in one pass — the old hardcoded
        // 20k clip default must not silently cut the middle out.
        let mock = MockChat(replies: ["HEADLINE: Budget\nSUMMARY:\n**Overview** — Fine."])
        let summarizer = MeetingSummarizer(chat: mock, transcriptCharBudget: 30_000)
        _ = try await summarizer.summarize(transcript(turns(count: 50, chars: 490)))
        #expect(mock.calls.count == 1)
        #expect(!userText(mock.calls[0]).contains("[… middle of transcript trimmed …]"))
    }

    @Test func mergePromptStaysWithinTheBudget() async throws {
        // ~7 sections whose notes come back at the model's verbose worst:
        // the merge prompt must still fit the instance budget. (Note the
        // per-note floor is 300 chars — the budget here is chosen so the
        // scaled allowance stays above it, matching real device budgets.)
        let noisyNote = String(repeating: "n", count: 3_000)
        let mock = MockChat(replies: Array(repeating: noisyNote, count: 12))
        let summarizer = MeetingSummarizer(chat: mock, transcriptCharBudget: 6_000)
        _ = try await summarizer.summarize(transcript(turns(count: 200, chars: 180)))
        let merge = userText(mock.calls[mock.calls.count - 1])
        #expect(merge.count <= 6_000)
        #expect(merge.contains("Section 1 notes:"))
    }

    @Test func overBudgetMonologueChunkIsClippedInItsSectionPrompt() async throws {
        // One 8k-char turn with a 2k budget becomes a single over-budget
        // chunk — its section prompt must be clipped, not sent whole.
        let mock = MockChat(replies: ["- note", "HEADLINE: Solo\nSUMMARY:\n**Overview** — One voice."])
        let summarizer = MeetingSummarizer(chat: mock, transcriptCharBudget: 2_000)
        _ = try await summarizer.summarize(transcript(turns(count: 1, chars: 8_000)))
        let section = userText(mock.calls[0])
        #expect(section.count <= 2_400)  // budget + prompt scaffolding slack
        #expect(section.contains("[… middle of transcript trimmed …]"))
    }

    @Test func contextOverheadCountsAgainstTheSinglePassCheck() async throws {
        // Transcript just under the raw budget + two fat participant
        // contexts: the combined prompt would blow the window, so the
        // summarizer must take the sectioned path instead.
        let fat = String(repeating: "c", count: 2_500)
        let context = [SummaryParticipant(name: "JD", context: fat),
                       SummaryParticipant(name: "Sam", context: fat)]
        let mock = MockChat(replies: Array(repeating: "- note", count: 6)
            + ["HEADLINE: Ctx\nSUMMARY:\n**Overview** — Ok."])
        let summarizer = MeetingSummarizer(chat: mock, transcriptCharBudget: 6_000)
        _ = try await summarizer.summarize(
            transcript(turns(count: 20, chars: 280)), context: context)
        #expect(mock.calls.count >= 2)  // sectioned, not single-pass
    }
}
```

- [ ] **Step 2: Run, verify failures**

Run: `swift test --filter SummarizerBudgetTests`
Expected: FAIL — `singlePassClipHonorsTheInstanceBudget` (trim marker present), `mergePromptStaysWithinTheBudget` (merge > 2,000), `overBudgetMonologueChunkIsClippedInItsSectionPrompt` (section ~8k), `contextOverheadCountsAgainstTheSinglePassCheck` (single call).

- [ ] **Step 3: Implement**

In `summarize` (lines 159-181), replace the budget check and prompt build:

```swift
        if Self.isEmpty(transcript) { return Self.emptyResult }
        if Self.isTooThin(transcript) { return Self.thinResult }
        // The budget covers the whole user prompt, so the reference block and
        // metadata spend against it before the transcript does — two rich
        // participant contexts alone are worth ~1,000 tokens.
        let overhead = Self.referenceBlock(context).count
            + Self.metadataBlock(for: transcript).count
        let available = max(1_000, transcriptCharBudget - overhead)
        if Self.turnLines(transcript.turns).count > available {
            return try await summarizeInSections(transcript, context: context, budget: available)
        }
        var sampling = ChatSamplingConfig.default
        sampling.temperature = 0.3
        sampling.maxTokens = 700
        let userPrompt = Self.userPrompt(for: transcript, context: context, clipLimit: available)
```

Change `userPrompt` (line 419) to take the limit:

```swift
    static func userPrompt(
        for transcript: MeetingTranscript,
        context: [SummaryParticipant] = [],
        clipLimit: Int = 20_000
    ) -> String {
        // Glossary FIRST, transcript LAST: recency and ordering make the
        // transcript the obvious (and only) thing to summarize, which stops the
        // small on-device model from confabulating a summary out of the rich
        // participant background.
        referenceBlock(context)
            + metadataBlock(for: transcript)
            + "\n\nTranscript:\n\(clip(turnLines(transcript.turns), limit: clipLimit))"
    }
```

Change `summarizeInSections` (line 186) to take and enforce the budget:

```swift
    nonisolated(nonsending) private func summarizeInSections(
        _ transcript: MeetingTranscript,
        context: [SummaryParticipant],
        budget: Int
    ) async throws -> (headline: String, overview: String) {
        let chunks = Self.splitTurns(transcript.turns, budget: budget)
        // The merge prompt re-spends the same budget: fixed merge prose plus
        // one "Section N notes:" wrapper per section, then the notes. Derive
        // the per-note allowance from the chunk count so the assembled merge
        // prompt always fits — thinner notes on very long meetings beat a
        // context-window error on every attempt.
        let mergeProse = 400
        let perNoteWrapper = 24
        let noteLimit = max(300, min(2_000, (budget - mergeProse) / max(chunks.count, 1) - perNoteWrapper))
        var sampling = ChatSamplingConfig.default
        sampling.temperature = 0.3
        sampling.maxTokens = 400
        var notes: [String] = []
        for (i, chunk) in chunks.enumerated() {
            let raw = try await chat.generate(
                messages: [
                    ChatMessage(role: .system, content: Self.sectionNotesSystemPrompt),
                    ChatMessage(role: .user, content: Self.sectionNotesPrompt(
                        part: i + 1, of: chunks.count, turns: chunk, clipLimit: budget)),
                ],
                sampling: sampling
            )
            // Debullet (the merge model copies "- " prefixes into its own
            // bullets, yielding "- - item") and clip — a runaway section
            // reply must not blow the merge pass's budget.
            notes.append(Self.clip(
                Self.debullet(raw.trimmingCharacters(in: .whitespacesAndNewlines)), limit: noteLimit))
        }
```

(rest of the method unchanged — the merge prompt build already uses these notes).

Change `sectionNotesPrompt` (line 626) to clip a single over-budget chunk (a monologue turn longer than the whole budget is never split by `splitTurns`):

```swift
    static func sectionNotesPrompt(
        part: Int, of total: Int, turns: [TranscriptTurn], clipLimit: Int = 20_000
    ) -> String {
        """
        This is part \(part) of \(total) of the meeting transcript.

        Transcript section:
        \(clip(turnLines(turns), limit: clipLimit))
        """
    }
```

- [ ] **Step 4: Run the full suite** (existing chunking/summarizer tests guard against regressions)

Run: `swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LuxiconKit/MeetingSummarizer.swift Tests/LuxiconKitTests/SummarizerTests.swift
git commit -m "Kit: summarizer prompts respect the instance budget — overhead-aware single pass, per-note merge allowance, clipped monologue sections"
```

---

### Task 6: Copy pass — docs and UI strings match the appleSpeech era

**Files:**
- Modify: `docs/privacy-policy.md:3,20-23`
- Modify: `README.md:28-41`
- Modify: `App/Sources/Views/SessionDetailView.swift:46`
- Modify: `App/Sources/Views/MyVoiceView.swift:153`
- Modify: `marketing/app-store.md:62-67,92-99,139+`
- Modify: `App/Sources/Store.swift:85-88` (doc comment only)

**Interfaces:** none (copy only).

- [ ] **Step 1: privacy-policy.md** — replace the first network bullet and bump the date:

Line 3: `*Effective 2026-07-14.*`

Replace lines 22-23 bullet with:

```markdown
- **Speech model downloads** (required, first use): diarization models are
  fetched from Hugging Face, and on iOS 26 and later the transcription model
  is Apple's system speech asset, downloaded by the OS from Apple (with
  Apple's built-in engine off or unavailable, a transcription model is
  fetched from Hugging Face instead). No user data is sent — these are file
  downloads.
```

- [ ] **Step 2: README.md lines 28-41** — replace with:

```markdown
All on-device, via [soniqo/speech-swift](https://github.com/soniqo/speech-swift)
and, on iOS 26+, Apple's system speech model:

- **Diarization** — Pyannote segmentation + WeSpeaker embeddings with
  constrained clustering, capped to 2 speakers for 1-on-1s
- **Transcription** — Apple's on-device system speech model (iOS 26+,
  default), or NVIDIA Parakeet TDT (CoreML) — the built-in engine and the
  pre-iOS-26 default; switchable in Settings
- **Speaker ID** — WeSpeaker enrollment matching (cosine similarity)

Models download on first use and are cached on-device: the diarization
models (and, when the Parakeet engine is used, transcription) from Hugging
Face — up to ~700 MB — plus a small live-caption model; Apple's system
speech model is downloaded and managed by the OS itself.
Summaries use the Apple Intelligence system model — OS-managed, no
download — and require an iPhone 15 Pro or later on iOS 26 or later; on
other devices, export the transcript and summarize it with any AI
assistant.
```

- [ ] **Step 3: SessionDetailView.swift:46** — engine-agnostic wording:

```swift
                Text("First run may download speech models (up to ~700 MB).")
```

- [ ] **Step 4: MyVoiceView.swift:153** — the fallback is engine-choice-independent; say so:

```swift
                    Text("Automatic uses Apple's on-device speech model on this iPhone. If the Apple engine can't start, transcription falls back to Luxicon's built-in engine. Everything stays on the device either way.")
```

- [ ] **Step 5: marketing/app-store.md** —

(a) In PRIVATE BY ARCHITECTURE (lines 63-67), replace the middle sentence:

```
Aside from one-time speech model downloads, Luxicon makes
no network connections unless you turn them on: pair a Mac and it can send
transcripts to that Mac over your own Wi-Fi (encrypted, never the
internet); point it at a vocabulary or people-roster file URL and it will
fetch those files.
```

(b) Nutrition label network bullet (lines 95-97), replace with:

```markdown
- Network use: speech model downloads (Hugging Face, and Apple's system
  speech asset on iOS 26+ — no user data), plus three opt-in,
  user-configured connections: Mac sync on the local network, and
  vocabulary / people-roster fetches from user-supplied https URLs.
```

(c) Append per-build TestFlight notes after the Build 9 section:

```markdown
### Build 10

New since build 9:

- Giving screen: the Davidson College credit on the root screen opens a
  giving page (links open in Safari).
- People-roster URL sync: point the app at a people JSON file and it keeps
  the roster synchronized; context fields become read-only while sync is on.
- Context rows are height-capped previews with a full-text editor screen.

### Build 11

New since build 10:

- Transcription engine picker (Settings → Transcription, iOS 26+):
  Automatic (Apple's system speech model, with automatic fallback),
  Apple, or Luxicon (built-in Parakeet). Please try a few meetings on
  each engine and compare transcript quality.
- Summaries now read every part of a long meeting (sectioned overview)
  instead of trimming the middle.
- Summary generation uses Apple Intelligence exclusively; the legacy
  downloaded summary model is removed and its disk space reclaimed.
```

- [ ] **Step 6: Store.swift:85-88** — fix the Gemma-era comment on `aiSummariesEnabled`:

```swift
    /// Master switch for the AI features (summaries, list labels, personal
    /// context). Off by default: enabling attaches to the Apple Intelligence
    /// system model (OS-managed, no download). When off, the summary and
    /// context UI is hidden entirely.
```

- [ ] **Step 7: Build the app** (two Swift files changed)

Run: `cd App && xcodebuild -project Luxicon.xcodeproj -scheme Luxicon -destination 'generic/platform=iOS' -configuration Release -allowProvisioningUpdates build 2>&1 | grep -E 'error:|BUILD'`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add docs/privacy-policy.md README.md marketing/app-store.md App/Sources/Views/SessionDetailView.swift App/Sources/Views/MyVoiceView.swift App/Sources/Store.swift
git commit -m "Docs/App: copy catches up with the appleSpeech engine — privacy policy, README, nutrition label, download hints, TestFlight notes for builds 10-11"
```

---

### Task 7: Dead code and stale-comment sweep

**Files:**
- Modify: `App/Sources/Store.swift:30` (remove `displayName`)
- Modify: `App/Sources/Views/MyVoiceView.swift:8` (remove unused `dismiss`)
- Modify: `Sources/LuxiconKit/AppleIntelligenceChat.swift:23-24` (remove `noModelDirectory`)
- Modify: `App/Sources/SummaryService.swift:172` (switch arm) and `:44` (force-unwrap)
- Modify: `Sources/LuxiconKit/MeetingSummarizer.swift:69-77` (doc-comment interleave), `:312-315` (Qwen think-block comment)
- Modify: `Sources/LuxiconKit/MeetingPipeline.swift:56` (`EngineUnavailableError` doc), `:167-172` (cache-cap comment)
- Modify: `Package.swift:16-17` (pin rationale)
- Modify: `scripts/build_mlx_metallib.sh:123` (test bundle name)
- Modify: `Tests/LuxiconKitTests/SummarizerTests.swift:43-44` (retired-backend comment)

**Interfaces:** removes `SummaryBackendError.noModelDirectory` (public enum case; only consumer is `SummaryService.summarizeErrorMessage`, updated here; not Codable/persisted).

- [ ] **Step 1: Apply the removals/edits**

Store.swift — delete line 30 (`var displayName: String { "Apple Intelligence" }`).

MyVoiceView.swift — delete line 8 (`@Environment(\.dismiss) private var dismiss`).

AppleIntelligenceChat.swift — delete lines 23-24 (the `noModelDirectory` case and its doc comment).

SummaryService.swift:172 — change `case .noModelDirectory, nil:` to `case nil:`.

SummaryService.swift:44 — replace the force-unwrap (unload during an await would crash a future edit):

```swift
        try await loadModel(progress: progress)
        progress("Summarizing…")
        try Task.checkCancellation()
        // loadModel guarantees a summarizer unless the feature was switched
        // off between the await and here — treat that race as a cancellation.
        guard let summarizer else { throw CancellationError() }
        let result = try await summarizer.summarize(transcript, context: context)
```

MeetingSummarizer.swift:69-77 — un-interleave the doc comments (the participant doc block sits above the wrong type):

```swift
/// One display block of a summary overview — see `MeetingSummarizer.overviewBlocks`.
public enum SummaryOverviewBlock: Equatable, Sendable {
    case paragraph(String)
    case bullet(level: Int, text: String)
}

/// Background knowledge about a meeting participant, injected into the
/// summarization prompt at call time — never persisted with the transcript,
/// so editing context improves the next regeneration.
public struct SummaryParticipant: Sendable, Equatable {
```

MeetingSummarizer.swift:312-315 — the comment cites the retired Qwen think-block behavior; replace:

```swift
        // Generous budget: a too-small cap yields an empty answer (and a
        // silent fallback to the unrefined headline).
        sampling.maxTokens = 256
```

MeetingPipeline.swift:56 — nothing catches this type specifically; fix the doc:

```swift
/// Load-time engine failure, surfaced to the user via `LocalizedError`
/// (the app treats any appleSpeech load failure as "fall back to Parakeet").
```

MeetingPipeline.swift:167-172 comment — last line currently says "Cap the cache for the run and drop it afterwards."; make it honest about the ratchet:

```swift
        // MLX keeps every freed GPU buffer in a cache, and diarization runs
        // ~3 embedding forward passes per 10 s window, each with a unique
        // input length — so on long recordings the cache only ever grows
        // (a 45-minute meeting reached iOS's ~6 GB per-process limit and was
        // jetsam-killed). Ratchet the process-wide cap down (min() never
        // raises it back) and drop the cache contents when the run ends.
```

Package.swift:16-17 — replace the pin comment:

```swift
        // Exact SHA past v0.0.21: the Parakeet streaming API this package
        // uses postdates the last upstream tag. Move to `from:` once a
        // release containing it is tagged.
```

build_mlx_metallib.sh:123 — this repo's test bundle, not the upstream project's:

```bash
  for BUNDLE_NAME in LuxiconPackageTests; do
```

SummarizerTests.swift:43-44 — replace the comment:

```swift
        // The summarizer must work over the SummaryChat protocol, not a
        // concrete model class — any backend slots in behind it.
```

- [ ] **Step 2: Build package + tests, build app**

Run: `swift build && swift test` then the Task 6 Step 7 xcodebuild command.
Expected: all pass, `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add App/Sources/Store.swift App/Sources/Views/MyVoiceView.swift Sources/LuxiconKit/AppleIntelligenceChat.swift App/Sources/SummaryService.swift Sources/LuxiconKit/MeetingSummarizer.swift Sources/LuxiconKit/MeetingPipeline.swift Package.swift scripts/build_mlx_metallib.sh Tests/LuxiconKitTests/SummarizerTests.swift
git commit -m "Kit/App: dead-code sweep — retire noModelDirectory and displayName, fix Gemma/Qwen-era comments, metallib copies to this package's test bundle"
```

---

### Task 8: Compiler warnings sweep

The app build emits 8 warnings, all in our files. Fix each at the source rather than suppressing.

**Files:**
- Modify: `App/Sources/Recorder.swift:145,335-345`
- Modify: `App/Sources/LiveCaptioner.swift:31`
- Modify: `Sources/LuxiconKit/Vocabulary.swift:233-242`

**Interfaces:** none (behavior-preserving except the documented main-thread hop in Vocabulary).

- [ ] **Step 1: Recorder.swift:145** — discard explicitly:

```swift
            if let fileURL {
                _ = try? WAVFile.repairHeader(url: fileURL, sampleRate: Self.sampleRate)
            }
```

(If `repairHeader` returns `Void` and the warning is about the unused `try?` expression itself, the `_ =` form still silences it correctly.)

- [ ] **Step 2: Recorder.swift `consume` converter closure** — mirror the documented pattern from `AppleSpeechTranscriber.pcmBuffer` (the input block is imported `@Sendable` but invoked synchronously and serially during this one `convert` call):

```swift
        // AVAudioConverterInputBlock is imported as @Sendable, but the
        // converter invokes it synchronously and serially on this thread
        // during this single `convert` call — never concurrently, never
        // stored past it (same contract as AppleSpeechTranscriber.pcmBuffer).
        nonisolated(unsafe) var fed = false
        nonisolated(unsafe) let inputBuffer = pcmBuffer
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return inputBuffer
        }
```

- [ ] **Step 3: LiveCaptioner.swift:31** — the class is `@Observable @MainActor`; the macro rewrites stored properties, so `nonisolated(unsafe)` lands on a computed property and does nothing. Keep it out of observation and on real storage:

```swift
    // Written once in init, read in deinit (nonisolated in Swift 6); the
    // observer closures capture only the thread-safe sink. @ObservationIgnored
    // keeps this real storage so nonisolated(unsafe) applies to it.
    @ObservationIgnored nonisolated(unsafe) private var lifecycleObservers: [NSObjectProtocol] = []
```

If the compiler still warns, apply its fix-it (`nonisolated` without `(unsafe)`) instead — the goal is zero warnings with the deinit access still legal.

- [ ] **Step 4: Vocabulary.swift `uiCheckerKnows`** — `UITextChecker` is `@MainActor` in the iOS 26 SDK; the pipeline calls this from a background thread. Hop to main explicitly (µs-scale per unknown word; the main actor is never blocked on the pipeline, so no deadlock cycle):

```swift
    #if canImport(UIKit) && !targetEnvironment(macCatalyst)
    static func uiCheckerKnows(_ word: String) -> Bool {
        // UITextChecker is main-actor-isolated (iOS 26 SDK). ASR correction
        // runs off-main, so hop; the main actor never awaits the pipeline
        // synchronously, so this cannot deadlock.
        if Thread.isMainThread {
            return MainActor.assumeIsolated { uiCheckerKnowsOnMain(word) }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { uiCheckerKnowsOnMain(word) }
        }
    }

    @MainActor private static func uiCheckerKnowsOnMain(_ word: String) -> Bool {
        let checker = UITextChecker()
        let range = NSRange(location: 0, length: word.utf16.count)
        let miss = checker.rangeOfMisspelledWord(
            in: word, range: range, startingAt: 0, wrap: false, language: "en_US")
        return miss.location == NSNotFound
    }

    /// A checker that "knows" gibberish has no loaded dictionary — ignore it.
    static let uiCheckerIsReliable: Bool = !uiCheckerKnows("xqzjvwqk")
    #else
```

- [ ] **Step 5: Verify zero warnings from our sources**

Run: `swift build && swift test`, then:
`cd App && xcodebuild -project Luxicon.xcodeproj -scheme Luxicon -destination 'generic/platform=iOS' -configuration Release -allowProvisioningUpdates build 2>&1 | grep -E 'warning:|error:|BUILD'`
Expected: `** BUILD SUCCEEDED **` with no `warning:` lines pointing into `App/Sources` or `Sources/LuxiconKit`.

- [ ] **Step 6: Commit**

```bash
git add App/Sources/Recorder.swift App/Sources/LiveCaptioner.swift Sources/LuxiconKit/Vocabulary.swift
git commit -m "App/Kit: zero compiler warnings — Sendable converter closures, observation-safe observer storage, main-actor UITextChecker hop"
```

---

### Task 9: Final verification and PR

- [ ] **Step 1: Full verification**

```bash
swift build && swift test
cd App && xcodegen generate && xcodebuild -project Luxicon.xcodeproj -scheme Luxicon \
  -destination 'generic/platform=iOS' -configuration Release -allowProvisioningUpdates build 2>&1 \
  | grep -E 'warning:|error:|BUILD'
```

Expected: all tests pass; `** BUILD SUCCEEDED **`; no warnings from repo sources.

- [ ] **Step 2: Push and open the PR**

```bash
git push -u origin qa/audit-fixes
gh pr create --title "QA audit fixes: silent-loss paths, summarizer budgets, copy pass, dead code + warnings" --body "..."
```

PR body summarizes the audit findings fixed, notes that `listener-v1.0.1` was already tagged from main, and flags the two human follow-ups: paste the new TestFlight notes when build 12 ships, and reinstall the Mac listener from the v1.0.1 release.
