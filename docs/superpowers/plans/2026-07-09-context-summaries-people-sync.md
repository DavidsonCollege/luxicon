# Topic Headlines, Per-Person Context, People Import/Sync — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Session headlines become short topic lists; a per-person free-text context field feeds the summarizer; a people roster gains vocab-style import/export and merge-never-delete URL sync.

**Architecture:** LuxiconKit gains `SummaryParticipant` (call-time summarizer context, never persisted) and `PeopleJSON`/`PersonImport` (mirroring `VocabularyJSON`). The app gains `Person.context` + `Store.myContext`, an `importPeople` merge, a `PeopleSync` store extension mirroring `VocabularySync` (with the GitHub-hint/error plumbing extracted into a shared `RemoteSync` helper), and a reusable `SyncSourceSection` view used by both sync settings sections.

**Tech Stack:** Swift 6 / SwiftUI / swift-testing (`import Testing`, `@Test`, `#expect`).

**Spec:** `docs/superpowers/specs/2026-07-09-context-aware-summaries-and-people-sync-design.md`

## Global Constraints

- Kit tests run with `swift test` on macOS from the repo root; no models or network needed. Use `@testable import LuxiconKit`.
- The App target has no unit tests. Compile-check app changes with: `cd App && xcodegen generate && xcodebuild -project Luxicon.xcodeproj -scheme Luxicon -destination 'generic/platform=iOS' -configuration Debug CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5` → `BUILD SUCCEEDED`. If the environment lacks xcodegen/iOS SDK, note it and rely on careful review — do not fight the toolchain.
- Sync remains https-only; secrets (header rows) live in the Keychain, never in `store.json`.
- New `Persisted` fields must be optional so existing `store.json` files decode unchanged.
- People sync merges and never deletes; only manual in-app deletion removes a person.
- Match surrounding comment style: comments state constraints, not narration.

---

### Task 1: Topic-list headlines (LuxiconKit)

**Files:**
- Modify: `Sources/LuxiconKit/MeetingSummarizer.swift` (systemPrompt line 44, parse cap lines 101-103)
- Modify: `Sources/LuxiconKit/Models.swift:102` (doc comment)
- Test: `Tests/LuxiconKitTests/SummarizerTests.swift`

**Interfaces:**
- Consumes: existing `MeetingSummarizer.parse(_:fallbackTitle:)`, `systemPrompt`.
- Produces: no signature changes; headline semantics become "comma-separated topics, ≤ 120 chars, no names".

- [ ] **Step 1: Update the tests.** In `SummarizerTests.swift`, change `truncatesRunawayHeadline` and add a prompt-shape test to `SummarizerParsingTests`:

```swift
@Test func truncatesRunawayHeadline() {
    let long = "HEADLINE: " + String(repeating: "word ", count: 40) + "\nSUMMARY:\nBody."
    let result = MeetingSummarizer.parse(long, fallbackTitle: "t")
    #expect(result.headline.count <= 120)
    #expect(result.overview == "Body.")
}

@Test func headlineInstructionAsksForTopicsWithoutNames() {
    #expect(MeetingSummarizer.systemPrompt.contains("topics"))
    #expect(MeetingSummarizer.systemPrompt.contains("120"))
    #expect(MeetingSummarizer.systemPrompt.contains("no people's names"))
}
```

- [ ] **Step 2: Run to verify failure.** Run: `swift test --filter SummarizerParsingTests 2>&1 | tail -10`
Expected: `headlineInstructionAsksForTopicsWithoutNames` FAILS (prompt says "at most 8 words"). `truncatesRunawayHeadline` passes either way (90 ≤ 120) — that's fine; it now pins the new cap.

- [ ] **Step 3: Implement.** In `MeetingSummarizer.swift`, replace the `HEADLINE:` line of `systemPrompt`:

```swift
    HEADLINE: <topics covered, comma-separated, under 120 characters — no people's names>
```

Replace the truncation in `parse`:

```swift
        if headline.count > 120 {
            headline = String(headline.prefix(117)) + "…"
        }
```

In `Models.swift`, replace the `headline` doc comment on `SessionSummary`:

```swift
    /// Comma-separated topics covered (≤ 120 chars) labeling the meeting in
    /// lists — no names; the session already hangs off a person.
    public var headline: String
```

- [ ] **Step 4: Run tests.** Run: `swift test --filter "SummarizerParsingTests|SummaryExportTests" 2>&1 | tail -5`
Expected: all PASS.

- [ ] **Step 5: Commit.**

```bash
git add Sources/LuxiconKit/MeetingSummarizer.swift Sources/LuxiconKit/Models.swift Tests/LuxiconKitTests/SummarizerTests.swift
git commit -m "feat: session headlines become topic lists (no names, ≤120 chars)"
```

---

### Task 2: Participant background in summarizer prompts (LuxiconKit)

**Files:**
- Modify: `Sources/LuxiconKit/MeetingSummarizer.swift` (`summarize`, `userPrompt`, `systemPrompt`)
- Test: `Tests/LuxiconKitTests/SummarizerTests.swift`

**Interfaces:**
- Produces (Task 4 and 5 rely on these exact signatures):

```swift
public struct SummaryParticipant: Sendable, Equatable {
    public var name: String
    public var context: String
    public init(name: String, context: String)
}
// on MeetingSummarizer:
public func summarize(_ transcript: MeetingTranscript,
                      context: [SummaryParticipant] = []) throws -> (headline: String, overview: String)
static func userPrompt(for transcript: MeetingTranscript,
                       context: [SummaryParticipant] = []) -> String
```

- [ ] **Step 1: Write failing tests.** Add to `SummarizerParsingTests` (reuse the transcript shape from `promptContainsTurnsAndParticipants`):

```swift
@Test func promptIncludesParticipantBackground() {
    let transcript = MeetingTranscript(
        title: "Weekly 1:1", date: Date(timeIntervalSince1970: 1_780_000_000),
        duration: 60,
        turns: [TranscriptTurn(id: 0, speakerId: 0, speakerName: "Josh", start: 0, end: 30, text: "Hi.")]
    )
    let prompt = MeetingSummarizer.userPrompt(for: transcript, context: [
        SummaryParticipant(name: "Josh", context: "Senior sysadmin; runs identity platform"),
        SummaryParticipant(name: "JD", context: "   "),
    ])
    #expect(prompt.contains("Participant background"))
    #expect(prompt.contains("- Josh: Senior sysadmin; runs identity platform"))
    // Blank context rows are dropped entirely, not emitted as empty lines.
    #expect(!prompt.contains("- JD:"))
}

@Test func promptOmitsBackgroundBlockWithoutContext() {
    let transcript = MeetingTranscript(
        title: "Weekly 1:1", date: Date(timeIntervalSince1970: 1_780_000_000),
        duration: 60,
        turns: [TranscriptTurn(id: 0, speakerId: 0, speakerName: "Josh", start: 0, end: 30, text: "Hi.")]
    )
    #expect(!MeetingSummarizer.userPrompt(for: transcript).contains("Participant background"))
}
```

- [ ] **Step 2: Run to verify failure.** Run: `swift test --filter SummarizerParsingTests 2>&1 | tail -10`
Expected: compile error — `SummaryParticipant` not defined.

- [ ] **Step 3: Implement.** In `MeetingSummarizer.swift`, above the class:

```swift
/// Background knowledge about a meeting participant, injected into the
/// summarization prompt at call time — never persisted with the transcript,
/// so editing context improves the next regeneration.
public struct SummaryParticipant: Sendable, Equatable {
    public var name: String
    public var context: String

    public init(name: String, context: String) {
        self.name = name
        self.context = context
    }
}
```

Change `summarize` to accept and forward context:

```swift
    /// Produce a headline + markdown overview. The caller stamps `generatedAt`.
    public func summarize(
        _ transcript: MeetingTranscript,
        context: [SummaryParticipant] = []
    ) throws -> (headline: String, overview: String) {
        var sampling = ChatSamplingConfig.default
        sampling.temperature = 0.3
        sampling.maxTokens = 700
        let raw = try chat.generate(
            messages: [
                ChatMessage(role: .system, content: Self.systemPrompt),
                ChatMessage(role: .user, content: Self.userPrompt(for: transcript, context: context)),
            ],
            sampling: sampling
        )
        return Self.parse(raw, fallbackTitle: transcript.title)
    }
```

Change `userPrompt` to append the background block after the transcript:

```swift
    static func userPrompt(
        for transcript: MeetingTranscript,
        context: [SummaryParticipant] = []
    ) -> String {
        let participants = transcript.speakers.map {
            "\($0.displayName) (\(Int(($0.talkShare * 100).rounded()))% talk time)"
        }.joined(separator: ", ")
        let lines = transcript.turns
            .map { "\($0.displayName): \($0.text)" }
            .joined(separator: "\n")
        var prompt = """
        Meeting: \(transcript.title)
        Date: \(transcript.date.formatted(date: .long, time: .shortened))
        Duration: \(TranscriptExport.timestamp(transcript.duration))
        Participants: \(participants)

        Transcript:
        \(clip(lines))
        """
        let background = context
            .map { ($0.name, $0.context.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.1.isEmpty }
        if !background.isEmpty {
            prompt += "\n\nParticipant background — use only to interpret the "
                + "conversation; never report it as something said in the meeting:\n"
                + background.map { "- \($0.0): \($0.1)" }.joined(separator: "\n")
        }
        return prompt
    }
```

- [ ] **Step 4: Run tests.** Run: `swift test 2>&1 | tail -3`
Expected: all PASS (full suite — `summarize`'s changed signature has a default, so nothing else breaks).

- [ ] **Step 5: Commit.**

```bash
git add Sources/LuxiconKit/MeetingSummarizer.swift Tests/LuxiconKitTests/SummarizerTests.swift
git commit -m "feat: summarizer accepts per-participant background context"
```

---

### Task 3: PeopleJSON exchange format (LuxiconKit)

**Files:**
- Create: `Sources/LuxiconKit/PeopleJSON.swift`
- Test (create): `Tests/LuxiconKitTests/PeopleJSONTests.swift`

**Interfaces:**
- Produces (Tasks 6-7 rely on these exact signatures):

```swift
public struct PersonImport: Codable, Sendable, Equatable {
    public var name: String
    public var context: String?
    public init(name: String, context: String? = nil)
}
public enum PeopleJSON {
    public static func export(_ people: [PersonImport]) throws -> Data
    public static func template(existing: [PersonImport]) throws -> Data
    public static func agentPrompt(existing: [PersonImport]) -> String
    public static func parse(_ data: Data) throws -> [PersonImport]
    public enum ParseError: Error, LocalizedError { case missingPeople, noEntries }
}
```

- [ ] **Step 1: Write failing tests.** Create `Tests/LuxiconKitTests/PeopleJSONTests.swift`:

```swift
import Testing
import Foundation
@testable import LuxiconKit

@Suite struct PeopleJSONTests {
    private let people = [
        PersonImport(name: "Priya Patel", context: "Senior sysadmin; runs identity platform"),
        PersonImport(name: "Josh Nguyen"),
    ]

    @Test func exportParseRoundTrip() throws {
        let parsed = try PeopleJSON.parse(PeopleJSON.export(people))
        #expect(parsed == people)
    }

    @Test func templateRoundTripsAndInstructionsAreIgnored() throws {
        let parsed = try PeopleJSON.parse(PeopleJSON.template(existing: people))
        #expect(parsed == people)
    }

    @Test func acceptsBareArrayStringsAndUnknownFields() throws {
        let json = """
        [
          {"name": "Priya Patel", "context": "runs identity platform", "photo": "ignored.jpg"},
          "Josh Nguyen",
          {"name": "  ", "context": "dropped"}
        ]
        """
        let parsed = try PeopleJSON.parse(Data(json.utf8))
        #expect(parsed == [
            PersonImport(name: "Priya Patel", context: "runs identity platform"),
            PersonImport(name: "Josh Nguyen"),
        ])
    }

    @Test func envelopeWithoutPeopleThrows() {
        #expect(throws: PeopleJSON.ParseError.self) {
            try PeopleJSON.parse(Data(#"{"kind": "luxicon-people"}"#.utf8))
        }
    }

    @Test func emptyPeopleThrows() {
        #expect(throws: PeopleJSON.ParseError.self) {
            try PeopleJSON.parse(Data(#"{"people": []}"#.utf8))
        }
    }
}

@Suite struct PeopleAgentPromptTests {
    @Test func promptEmbedsCurrentPeopleAndSchema() {
        let prompt = PeopleJSON.agentPrompt(existing: [
            PersonImport(name: "Priya Patel", context: "identity platform"),
        ])
        #expect(prompt.contains("\"kind\": \"luxicon-people\""))
        #expect(prompt.contains("Priya Patel"))
        #expect(prompt.contains("Return only the finished JSON"))
    }

    @Test func promptHandlesEmptyRoster() {
        #expect(PeopleJSON.agentPrompt(existing: []).contains("(none yet)"))
    }
}
```

- [ ] **Step 2: Run to verify failure.** Run: `swift test --filter PeopleJSONTests 2>&1 | tail -5`
Expected: compile error — `PersonImport`/`PeopleJSON` not defined.

- [ ] **Step 3: Implement.** Create `Sources/LuxiconKit/PeopleJSON.swift`:

```swift
import Foundation

/// One roster record in the people exchange format — the Kit-level shape;
/// the app maps it onto its own `Person` (which also owns photos/sessions).
public struct PersonImport: Codable, Sendable, Equatable {
    public var name: String
    /// Background for the summarizer: role, projects, current threads.
    public var context: String?

    public init(name: String, context: String? = nil) {
        self.name = name
        self.context = context
    }
}

/// JSON exchange format for the people roster — the shape an AI agent or a
/// web service should produce:
///
/// ```json
/// {
///   "kind": "luxicon-people",
///   "schemaVersion": 1,
///   "people": [
///     {"name": "Priya Patel", "context": "Senior sysadmin; runs identity platform"}
///   ]
/// }
/// ```
///
/// Parsing is deliberately liberal: a bare array works, entries may be plain
/// strings (name only), and unknown fields are ignored. Importing merges by
/// name and never deletes — see `Store.importPeople`.
public enum PeopleJSON {

    public static func export(_ people: [PersonImport]) throws -> Data {
        try envelope(people: people, instructions: nil)
    }

    /// Starter file with inline instructions for whoever (or whatever) fills it in.
    public static func template(existing: [PersonImport]) throws -> Data {
        try envelope(
            people: existing,
            instructions: """
            Add one object per person to "people". Fields: name (required — \
            as it should appear in transcripts, e.g. "Priya Patel"); context \
            (background that helps meeting summaries: role, projects, current \
            threads). Importing adds new people and updates context on \
            matching names; it never removes anyone.
            """
        )
    }

    /// A ready-to-paste prompt for an AI assistant that produces an
    /// importable roster file, with the current people embedded so the
    /// agent extends rather than starts over.
    public static func agentPrompt(existing: [PersonImport]) -> String {
        let current: String
        if existing.isEmpty {
            current = "(none yet)"
        } else {
            current = (try? export(existing)).flatMap { String(data: $0, encoding: .utf8) }
                ?? "(none yet)"
        }
        return """
        Help me maintain the roster for my 1-on-1 meeting recorder (Luxicon). \
        Build a people file listing everyone I hold 1-on-1s with, plus \
        background context that helps an on-device model summarize our \
        meetings.

        Output valid JSON only, in exactly this format:

        {
          "kind": "luxicon-people",
          "schemaVersion": 1,
          "people": [
            {"name": "Priya Patel", "context": "Senior sysadmin; runs the identity platform; discussing promotion this quarter"}
          ]
        }

        Rules:
        - "name": the person's name exactly as it should appear in transcripts.
        - "context": 1-3 sentences of background — role, projects, recurring \
        topics. Write it for a summarizer that has never met them.
        - Importing merges by name and never removes anyone, so include only \
        people to add or update.

        If I haven't provided source material, ask me for a team roster or \
        org chart before guessing.

        My current people — extend and improve, keeping existing entries \
        unless they are clearly wrong:

        \(current)

        Return only the finished JSON, ready to import.
        """
    }

    public static func parse(_ data: Data) throws -> [PersonImport] {
        let root = try JSONSerialization.jsonObject(with: data)
        let rawPeople: [Any]
        if let envelope = root as? [String: Any] {
            guard let people = envelope["people"] as? [Any] else {
                throw ParseError.missingPeople
            }
            rawPeople = people
        } else if let array = root as? [Any] {
            rawPeople = array
        } else {
            throw ParseError.missingPeople
        }

        let records = rawPeople.compactMap(record(from:))
        guard !records.isEmpty else { throw ParseError.noEntries }
        return records
    }

    public enum ParseError: Error, LocalizedError {
        case missingPeople
        case noEntries

        public var errorDescription: String? {
            switch self {
            case .missingPeople:
                return "Expected a JSON object with a \"people\" array (or a bare array of people)."
            case .noEntries:
                return "No people found in the file."
            }
        }
    }

    // MARK: - Internals

    private static func record(from raw: Any) -> PersonImport? {
        if let name = raw as? String {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : PersonImport(name: trimmed)
        }
        guard let dict = raw as? [String: Any],
              let name = (dict["name"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return PersonImport(name: name, context: nonEmpty(dict["context"] as? String))
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    private static func envelope(people: [PersonImport], instructions: String?) throws -> Data {
        var root: [String: Any] = [
            "kind": "luxicon-people",
            "schemaVersion": 1,
            "people": people.map { person -> [String: Any] in
                var obj: [String: Any] = ["name": person.name]
                if let context = person.context { obj["context"] = context }
                return obj
            },
        ]
        if let instructions { root["instructions"] = instructions }
        return try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }
}
```

- [ ] **Step 4: Run tests.** Run: `swift test --filter "PeopleJSONTests|PeopleAgentPromptTests" 2>&1 | tail -5`
Expected: all PASS. Then `swift test 2>&1 | tail -3` → all PASS.

- [ ] **Step 5: Commit.**

```bash
git add Sources/LuxiconKit/PeopleJSON.swift Tests/LuxiconKitTests/PeopleJSONTests.swift
git commit -m "feat: PeopleJSON exchange format (export, template, agent prompt, liberal parse)"
```

---

### Task 4: App model — Person.context, myContext, summarizer wiring

**Files:**
- Modify: `App/Sources/Store.swift` (Person struct, Store fields, Persisted, load/save)
- Modify: `App/Sources/SummaryService.swift`

**Interfaces:**
- Consumes: `SummaryParticipant`, `MeetingSummarizer.summarize(_:context:)` from Task 2.
- Produces (Task 5 relies on): `Person.context: String?` (declared after `photoFileName`, so `Person(name:)` and `Person(name:context:)` both work via the memberwise init); `Store.myContext: String`.

- [ ] **Step 1: Add the fields.** In `App/Sources/Store.swift`:

`Person` gains context (after `photoFileName`, keeping memberwise-init call sites valid):

```swift
/// A direct report you hold 1-on-1s with.
struct Person: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// Profile picture file in `Store.photosDirURL`, if one has been set.
    var photoFileName: String?
    /// Background for the summarizer: role, projects, current threads.
    var context: String?
}
```

`Store` gains (next to `myName`):

```swift
    /// Background about the user fed to the summarizer, like `Person.context`.
    var myContext: String = ""
```

`Persisted` gains (next to `myPhotoFileName`):

```swift
        var myContext: String?
```

In `load()` (after `myVoiceEmbedding = ...`):

```swift
        myContext = persisted.myContext ?? ""
```

In `save()`, add to the `Persisted(...)` call after `myPhotoFileName: myPhotoFileName,`:

```swift
            myContext: myContext.isEmpty ? nil : myContext,
```

- [ ] **Step 2: Wire context into summarization.** In `App/Sources/SummaryService.swift`:

```swift
    func summarize(
        _ transcript: MeetingTranscript,
        context: [SummaryParticipant],
        progress: @Sendable @escaping (String) -> Void
    ) async throws -> SessionSummary {
```

…and the call becomes `try summarizer!.summarize(transcript, context: context)`. In `Store.startSummarizing`, build the array before the `Task` (Person values are Sendable-friendly copies):

```swift
        var context = [SummaryParticipant(name: myName, context: myContext)]
        if let person = person(id: session.personId) {
            context.append(SummaryParticipant(name: person.name, context: person.context ?? ""))
        }
```

…and pass it: `try await SummaryService.shared.summarize(transcript, context: context) { stage in`.

- [ ] **Step 3: Compile check.** `swift build 2>&1 | tail -3` (Kit unaffected but cheap), then the xcodebuild command from Global Constraints. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit.**

```bash
git add App/Sources/Store.swift App/Sources/SummaryService.swift
git commit -m "feat: per-person context fields feed the summarizer"
```

---

### Task 5: Context editing UI

**Files:**
- Modify: `App/Sources/Views/PersonDetailView.swift`
- Modify: `App/Sources/Views/MyVoiceView.swift` ("Your name" section)

**Interfaces:**
- Consumes: `Person.context`, `Store.myContext` from Task 4.

- [ ] **Step 1: Person context section.** In `PersonDetailView`, after the Record button `Section` and before the sessions section, add:

```swift
            Section {
                TextField("Role, projects, current threads…",
                          text: contextBinding, axis: .vertical)
                    .lineLimit(2...6)
            } header: {
                Text("Context")
            } footer: {
                Text("Background the summarizer uses to interpret your 1-on-1s — e.g. “Senior sysadmin; runs the identity platform; discussing promotion this quarter.” Stays on this device.")
            }
```

Add the binding (route values carry a stale `Person` copy — same rule as photos, edit via the store by id) and save on exit. Add to the view:

```swift
    /// Route values carry a stale Person copy; edit context via the store.
    private var contextBinding: Binding<String> {
        Binding(
            get: { store.person(id: person.id)?.context ?? "" },
            set: { newValue in
                guard let i = store.people.firstIndex(where: { $0.id == person.id }) else { return }
                store.people[i].context = newValue.isEmpty ? nil : newValue
            }
        )
    }
```

…and append to the `List`'s modifiers (near `.onAppear { writeHistoryFiles() }`):

```swift
        .onDisappear { store.save() }
```

- [ ] **Step 2: "About you" field.** In `MyVoiceView`'s `Section("Your name")`, after the existing `HStack`:

```swift
                TextField("About you — role, team, current focus", text: $store.myContext, axis: .vertical)
                    .lineLimit(2...6)
```

(`onDisappear` already calls `store.save()`.)

- [ ] **Step 3: Compile check.** xcodebuild command from Global Constraints. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit.**

```bash
git add App/Sources/Views/PersonDetailView.swift App/Sources/Views/MyVoiceView.swift
git commit -m "feat: edit summarizer context on person detail and My Voice"
```

---

### Task 6: importPeople merge + People list import/export menu

**Files:**
- Modify: `App/Sources/Store.swift` (next to `importVocabulary`)
- Modify: `App/Sources/Views/PeopleListView.swift`

**Interfaces:**
- Consumes: `PeopleJSON`, `PersonImport` (Task 3); `Person.context` (Task 4).
- Produces (Task 7 relies on): `Store.importPeople(_ imported: [PersonImport]) -> (added: Int, updated: Int)`.

- [ ] **Step 1: Merge logic.** In `Store.swift`, below `importVocabulary`:

```swift
    /// Merge an imported roster by case-insensitive name: new people are
    /// appended, matches get their context updated when the import provides
    /// one. Never removes anyone — photos and sessions are untouched.
    func importPeople(_ imported: [PersonImport]) -> (added: Int, updated: Int) {
        var added = 0, updated = 0
        for record in imported {
            if let i = people.firstIndex(where: {
                $0.name.caseInsensitiveCompare(record.name) == .orderedSame
            }) {
                if let context = record.context, people[i].context != context {
                    people[i].context = context
                    updated += 1
                }
            } else {
                people.append(Person(name: record.name, context: record.context))
                added += 1
            }
        }
        save()
        return (added, updated)
    }

    /// Roster in the Kit exchange shape, for export and agent prompts.
    var peopleForExport: [PersonImport] {
        people.map { PersonImport(name: $0.name, context: $0.context) }
    }
```

(`import LuxiconKit` is already present in Store.swift.)

- [ ] **Step 2: Toolbar menu.** In `PeopleListView.swift`, add `import LuxiconKit` below `import SwiftUI`, and add state next to `newPersonName`:

```swift
    @State private var peopleFileURL: URL?
    @State private var importingPeople = false
    @State private var importResult: String?
```

Replace the existing `.primaryAction` ToolbarItem (keep the plus, add a menu beside it):

```swift
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddPerson = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            importingPeople = true
                        } label: {
                            Label("Import People…", systemImage: "square.and.arrow.down")
                        }
                        if let peopleFileURL {
                            ShareLink(item: peopleFileURL) {
                                Label("Export People", systemImage: "square.and.arrow.up")
                            }
                        }
                        ShareLink(item: PeopleJSON.agentPrompt(existing: store.peopleForExport)) {
                            Label("Share Agent Prompt", systemImage: "sparkles")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
```

Add the file plumbing to the `NavigationStack`'s modifiers (mirroring `VocabularyListView`):

```swift
            .onAppear { writePeopleFile(); handleRouteArgument() }
            .onChange(of: store.people) { writePeopleFile() }
            .fileImporter(
                isPresented: $importingPeople,
                allowedContentTypes: [.json, .plainText, .text]
            ) { result in
                importPeople(result)
            }
            .alert("People Import", isPresented: Binding(
                get: { importResult != nil },
                set: { if !$0 { importResult = nil } }
            )) {
                Button("OK") { importResult = nil }
            } message: {
                Text(importResult ?? "")
            }
```

(The `.onAppear { handleRouteArgument() }` already exists — fold `writePeopleFile()` into it rather than adding a second `.onAppear`.) Add the helpers:

```swift
    /// ShareLink needs a file URL ready before the tap.
    private func writePeopleFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Luxicon People.json")
        if let data = try? PeopleJSON.template(existing: store.peopleForExport) {
            try? data.write(to: url)
            peopleFileURL = url
        }
    }

    private func importPeople(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let records = try PeopleJSON.parse(Data(contentsOf: url))
            let (added, updated) = store.importPeople(records)
            importResult = "Added \(added), updated \(updated). Nobody is removed by imports."
        } catch {
            importResult = "Import failed: \(error.localizedDescription)"
        }
    }
```

- [ ] **Step 3: Compile check.** xcodebuild command from Global Constraints. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit.**

```bash
git add App/Sources/Store.swift App/Sources/Views/PeopleListView.swift
git commit -m "feat: people import/export with merge-never-delete semantics"
```

---

### Task 7: People URL sync + shared RemoteSync helper

**Files:**
- Create: `App/Sources/RemoteSync.swift`
- Create: `App/Sources/PeopleSync.swift`
- Modify: `App/Sources/VocabularySync.swift` (use the shared helper)
- Modify: `App/Sources/Store.swift` (people sync fields)
- Modify: `App/Sources/LuxiconApp.swift:21` (trigger)

**Interfaces:**
- Consumes: `Store.importPeople` (Task 6), `PeopleJSON.parse` (Task 3), `KeychainStore`.
- Produces (Task 8 relies on): `Store.peopleSourceURL: String`, `Store.peopleHeaders: [Store.HTTPHeader]`, `Store.peopleLastSync: Date?`, `Store.peopleSyncError: String?`, `func syncPeople() async`, `func syncPeopleIfConfigured()`.

- [ ] **Step 1: Extract the shared helper.** Create `App/Sources/RemoteSync.swift` — the hint and error type moved verbatim from `VocabularySync.swift`, plus the request builder both syncs share:

```swift
import Foundation

/// Shared plumbing for URL-sourced sync (vocabulary, people): request
/// building with sanitized auth headers, and status errors with
/// GitHub-specific credential hints.
enum RemoteSync {

    /// Trim newlines too: a pasted token with a trailing newline makes
    /// CFNetwork silently drop the header. Skip blank rows entirely so an
    /// accidentally-added duplicate can't overwrite a real one (setValue
    /// replaces any earlier value for the same name).
    static func request(url: URL, headers: [Store.HTTPHeader]) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 15)
        for header in headers {
            let name = header.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = header.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !value.isEmpty else { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    /// GitHub answers 404, not 401, for private files, which hides whether
    /// the problem is the URL, the credentials, or the token's access. Its
    /// rate-limit ceiling tells them apart: 60/hour means the request was
    /// treated as anonymous; authenticated requests get 5000+.
    static func gitHubHint(for response: HTTPURLResponse) -> String? {
        guard response.statusCode == 404,
              response.url?.host == "api.github.com" else { return nil }
        let limit = response.value(forHTTPHeaderField: "x-ratelimit-limit")
            .flatMap(Int.init) ?? 0
        return limit <= 60
            ? "GitHub did not receive valid credentials — check the Authorization header row (value: “Bearer <token>”)."
            : "GitHub recognized your token, but it does not grant access to this file — check the token's Repository access and Contents permission, and the file path."
    }

    enum SyncError: Error, LocalizedError {
        case badStatus(Int, hint: String?)
        var errorDescription: String? {
            switch self {
            case .badStatus(let code, let hint):
                let message = "Server returned HTTP \(code)."
                if let hint { return message + " " + hint }
                if code == 404 {
                    // Same ambiguity on non-GitHub hosts; say so generically.
                    return message + " Check the URL — private files can also return 404 when the Authorization header is missing or invalid."
                }
                return message
            }
        }
    }
}
```

In `VocabularySync.swift`, delete the private `gitHubHint` and `SyncError`, and replace the request-building block (the `var request = URLRequest(...)` through the header loop) with:

```swift
        let request = RemoteSync.request(url: url, headers: vocabularyHeaders)
```

…and the throw with:

```swift
                throw RemoteSync.SyncError.badStatus(http.statusCode, hint: RemoteSync.gitHubHint(for: http))
```

- [ ] **Step 2: Store fields.** In `Store.swift`, next to the vocabulary sync fields:

```swift
    /// Remote people roster kept in sync; unlike vocabulary, each sync
    /// merges (adds/updates by name) and never removes anyone.
    var peopleSourceURL: String = ""
    var peopleHeaders: [HTTPHeader] = []
    var peopleLastSync: Date?
    /// Transient sync status for the UI; not persisted.
    var peopleSyncError: String?
    @ObservationIgnored var peopleLastSyncAttempt: Date?
```

Next to `keychainVocabHeaders`:

```swift
    private static let keychainPeopleHeaders = "peopleHeaders"
```

`Persisted` gains:

```swift
        var peopleSourceURL: String?
        var peopleLastSync: Date?
```

In `load()`, next to the vocabularyHeaders Keychain read:

```swift
        peopleHeaders = KeychainStore.data(for: Self.keychainPeopleHeaders)
            .flatMap { try? JSONDecoder().decode([HTTPHeader].self, from: $0) } ?? []
```

…and with the other persisted reads:

```swift
        peopleSourceURL = persisted.peopleSourceURL ?? ""
        peopleLastSync = persisted.peopleLastSync
```

In `save()`, next to the vocab headers Keychain write:

```swift
        KeychainStore.set(
            peopleHeaders.isEmpty ? nil : try? JSONEncoder().encode(peopleHeaders),
            for: Self.keychainPeopleHeaders)
```

…and in the `Persisted(...)` call (after `vocabularyLastSync:`):

```swift
            peopleSourceURL: peopleSourceURL.isEmpty ? nil : peopleSourceURL,
            peopleLastSync: peopleLastSync,
```

- [ ] **Step 3: The sync extension.** Create `App/Sources/PeopleSync.swift`:

```swift
import Foundation
import LuxiconKit

/// Keeps the people roster synchronized with a user-provided URL. Unlike
/// vocabulary sync, the remote file is NOT the source of truth: each sync
/// merges via `importPeople` (adds/updates by name) and never removes
/// anyone — a Person owns sessions and photos that sync must not destroy.
/// Runs on foreground activation (rate-limited) and on demand via Sync Now.
extension Store {
    private static let peopleSyncCooldown: TimeInterval = 60

    /// Foreground/auto trigger; skips if unconfigured or synced recently.
    func syncPeopleIfConfigured() {
        guard !peopleSourceURL.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if let last = peopleLastSyncAttempt,
           Date().timeIntervalSince(last) < Self.peopleSyncCooldown { return }
        Task { await syncPeople() }
    }

    /// One sync pass. Errors land in `peopleSyncError` for the UI.
    func syncPeople() async {
        let urlString = peopleSourceURL.trimmingCharacters(in: .whitespaces)
        guard !urlString.isEmpty else { return }
        guard let url = URL(string: urlString), url.scheme?.lowercased() == "https" else {
            peopleSyncError = "Not a valid https URL. (Plain http would expose your auth headers.)"
            return
        }
        peopleLastSyncAttempt = Date()

        let request = RemoteSync.request(url: url, headers: peopleHeaders)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                throw RemoteSync.SyncError.badStatus(http.statusCode, hint: RemoteSync.gitHubHint(for: http))
            }
            let records = try PeopleJSON.parse(data)
            _ = importPeople(records)
            peopleLastSync = Date()
            peopleSyncError = nil
            save()
        } catch {
            peopleSyncError = error.localizedDescription
        }
    }
}
```

- [ ] **Step 4: Trigger on foreground.** In `LuxiconApp.swift`, after `store.syncVocabularyIfConfigured()`:

```swift
                store.syncPeopleIfConfigured()
```

- [ ] **Step 5: Compile check.** xcodebuild command from Global Constraints. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit.**

```bash
git add App/Sources/RemoteSync.swift App/Sources/PeopleSync.swift App/Sources/VocabularySync.swift App/Sources/Store.swift App/Sources/LuxiconApp.swift
git commit -m "feat: people URL sync (merge-never-delete) with shared RemoteSync plumbing"
```

---

### Task 8: SyncSourceSection view + People sync settings UI

**Files:**
- Create: `App/Sources/Views/SyncSourceSection.swift`
- Modify: `App/Sources/Views/MyVoiceView.swift` (replace the inline vocab sync section; add people sync; delete `headerBinding`)

**Interfaces:**
- Consumes: Task 7's Store fields and `syncPeople()`/`syncVocabulary()`.

- [ ] **Step 1: Extract the section view.** Create `App/Sources/Views/SyncSourceSection.swift`:

```swift
import SwiftUI

/// One "keep this list synced from a URL" settings section: URL field,
/// collapsible auth-header rows, Sync Now, and a status footer. Used for
/// both vocabulary and people sync in MyVoiceView.
struct SyncSourceSection: View {
    let title: String
    let urlPlaceholder: String
    @Binding var sourceURL: String
    @Binding var headers: [Store.HTTPHeader]
    let lastSync: Date?
    let syncError: String?
    /// Footer before the URL is configured.
    let idleFooter: String
    /// Footer once synced — states the semantics (replace vs merge).
    let syncedFooter: String
    let onSave: () -> Void
    let onSync: () -> Void

    var body: some View {
        Section {
            TextField(urlPlaceholder, text: $sourceURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit {
                    onSave()
                    onSync()
                }
            if !sourceURL.isEmpty {
                DisclosureGroup("Request Headers") {
                    // Id-based bindings, not ForEach($...): rows outlive
                    // removal by one render pass, and a positional binding
                    // read after the array shrinks crashes.
                    ForEach(headers) { header in
                        HStack {
                            // Explicit remove button: swipe-to-delete is
                            // unreliable inside a DisclosureGroup.
                            Button {
                                headers.removeAll { $0.id == header.id }
                                onSave()
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            TextField("Header", text: headerBinding(header.id, \.name))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .frame(maxWidth: 140)
                            Divider()
                            TextField("Value", text: headerBinding(header.id, \.value))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        .font(.callout.monospaced())
                    }
                    .onDelete { offsets in
                        headers.remove(atOffsets: offsets)
                        onSave()
                    }
                    Button {
                        headers.append(Store.HTTPHeader())
                    } label: {
                        Label("Add Header", systemImage: "plus")
                    }
                }
                Button {
                    onSave()
                    onSync()
                } label: {
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                }
            }
        } header: {
            Text(title)
        } footer: {
            if let syncError {
                Text("Sync failed: \(syncError)")
                    .foregroundStyle(.red)
            } else if let lastSync, !sourceURL.isEmpty {
                Text("Synced \(lastSync.formatted(.relative(presentation: .named))). \(syncedFooter)")
            } else {
                Text(idleFooter)
            }
        }
    }

    /// Binding into a header row by id; reads return "" and writes no-op
    /// once the row has been removed, so a stale row can't trap.
    private func headerBinding(
        _ id: UUID, _ keyPath: WritableKeyPath<Store.HTTPHeader, String>
    ) -> Binding<String> {
        Binding(
            get: { headers.first { $0.id == id }?[keyPath: keyPath] ?? "" },
            set: { newValue in
                guard let i = headers.firstIndex(where: { $0.id == id }) else { return }
                headers[i][keyPath: keyPath] = newValue
            }
        )
    }
}
```

- [ ] **Step 2: Use it twice in MyVoiceView.** Delete the entire inline "Vocabulary sync" `Section` (the URL field, DisclosureGroup, Sync Now, and its header/footer) and the now-unused `headerBinding(_:_:)` helper at the bottom of the view. In their place:

```swift
            SyncSourceSection(
                title: "Vocabulary sync",
                urlPlaceholder: "https://example.com/vocabulary.json",
                sourceURL: $store.vocabularySourceURL,
                headers: $store.vocabularyHeaders,
                lastSync: store.vocabularyLastSync,
                syncError: store.vocabularySyncError,
                idleFooter: "Point at a JSON vocabulary file (same format as the export) and Luxicon will keep the list synchronized whenever the app opens. The file replaces the vocabulary list; add auth via Request Headers if needed.",
                syncedFooter: "The file at this URL replaces the vocabulary list on each sync — edit it there, not here. Headers are sent with every request (for example an Authorization token).",
                onSave: { store.save() },
                onSync: { Task { await store.syncVocabulary() } }
            )

            SyncSourceSection(
                title: "People sync",
                urlPlaceholder: "https://example.com/people.json",
                sourceURL: $store.peopleSourceURL,
                headers: $store.peopleHeaders,
                lastSync: store.peopleLastSync,
                syncError: store.peopleSyncError,
                idleFooter: "Point at a JSON people file (same format as Export People) and Luxicon will keep the roster synchronized whenever the app opens. Syncing adds and updates people (name and context) and never removes anyone.",
                syncedFooter: "Syncing adds and updates people (name and context) and never removes anyone — remove people manually in the list. Headers are sent with every request (for example an Authorization token).",
                onSave: { store.save() },
                onSync: { Task { await store.syncPeople() } }
            )
```

- [ ] **Step 3: Compile check.** xcodebuild command from Global Constraints. Expected: `BUILD SUCCEEDED`. Manually verify (simulator or device if available): both sections render, vocab sync still works, People sync Sync Now merges a test file. If no simulator is available, note it for the human to verify.

- [ ] **Step 4: Commit.**

```bash
git add App/Sources/Views/SyncSourceSection.swift App/Sources/Views/MyVoiceView.swift
git commit -m "feat: People sync settings; extract shared SyncSourceSection view"
```

---

### Task 9: Changelog + full verification

**Files:**
- Modify: `CHANGELOG.md` (under `## 1.0 (build 6) — unreleased`)

- [ ] **Step 1: Changelog.** Add a block under the build-6 heading, after the QA list:

```markdown
New in this build:

- Session headlines are now short topic lists (no names — the session
  already sits under a person).
- Per-person context: a free-text field on each person (and an "About you"
  field in My Voice) gives the summarizer background it can use.
- People import/export and URL sync, modeled on vocabulary sync but
  merge-only: syncing adds and updates people, never removes anyone.
```

- [ ] **Step 2: Full verification.** Run: `swift build && swift test 2>&1 | tail -3` → all pass. Run the xcodebuild command from Global Constraints → `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit.**

```bash
git add CHANGELOG.md
git commit -m "docs: changelog for topic headlines, context fields, people sync"
```
