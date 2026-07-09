# Context-aware summaries and people import/sync — design

Date: 2026-07-09
Status: approved

Three related changes to Luxicon:

1. Session headlines become a short topic list (no names, ≤ 120 characters).
2. A free-text context field per person — one for the user, one for each
   staff member — feeds the summarizer so it produces better output.
3. A people import/export/sync feature modeled on vocabulary sync, with
   merge-never-delete semantics.

## Decisions made during brainstorming

- **Sync model:** merge, never delete. Sync upserts by name; people are only
  ever removed manually in the app. (A `Person` owns sessions, photos, and
  context locally — replace semantics would destroy data.)
- **Sync config:** fully separate from vocabulary sync — its own URL and its
  own header rows (own Keychain key).
- **Context plumbing:** context is passed to the summarizer at call time,
  not stamped into `MeetingTranscript`. Editing context improves the next
  (re)generated summary; persisted transcript models are unchanged.
- **UI placement:** import/export actions live in a toolbar menu on the
  People list; the sync URL/headers/Sync Now live in a "People sync"
  section in My Voice, next to "Vocabulary sync".

## 1. Topics-only headlines

`MeetingSummarizer.systemPrompt` (Sources/LuxiconKit/MeetingSummarizer.swift)
changes its `HEADLINE:` instruction from "at most 8 words naming what this
meeting was about" to a comma-separated list of topics covered — no people's
names (the session already hangs off a person, so names are inferred from
placement), under 120 characters. Example output:

```
Q3 roadmap, hiring pipeline, on-call burnout
```

- `parse(_:fallbackTitle:)` truncation cap rises from 90 to 120 characters
  (truncate to 117 + "…").
- `SessionSummary.headline` doc comment updates to describe the new shape.
- Existing stored summaries are untouched. The existing per-session
  Generate Summary action regenerates with the new prompt; no migration.

## 2. Per-person context

### Model

- `Person` (App/Sources/Store.swift) gains `var context: String?`.
  Optional, so existing `store.json` files decode unchanged.
- `Store` gains `var myContext: String = ""`, persisted via a new optional
  field in `Persisted` (same pattern as `myName`).

### Summarizer

- New public type in LuxiconKit:

  ```swift
  public struct SummaryParticipant: Sendable {
      public var name: String
      public var context: String
  }
  ```

- `MeetingSummarizer.summarize(_:context:)` takes
  `context: [SummaryParticipant] = []`. The user-prompt builder appends a
  "Participant background" block containing one `About <name>: <context>`
  line per participant with non-empty context, plus an instruction that
  background is for interpretation only and must never be reported as
  something said in the meeting unless the transcript supports it.
- `SummaryService.summarize` passes the array through.
  `Store.startSummarizing` builds it from (`myName`, `myContext`) and the
  session's person (`person(id: session.personId)`).

### UI

- `PersonDetailView`: new "Context" section with a multiline
  `TextField(axis: .vertical)`. Edits go through the store by person id
  (route values carry stale `Person` copies — same rule as photos).
  Footer explains useful content: role, projects, current threads.
- `MyVoiceView`: "About you" multiline field in the "Your name" section,
  bound to `store.myContext`, saved like `myName`.

## 3. People JSON format + import/export

New `PeopleJSON` enum in LuxiconKit mirroring `VocabularyJSON`:

```json
{
  "kind": "luxicon-people",
  "schemaVersion": 1,
  "people": [
    {"name": "Priya Patel", "context": "Senior sysadmin; runs identity platform"}
  ]
}
```

- Deals in a Kit-level record `PersonImport { name: String, context: String? }`
  (`Person` is an app type; LuxiconKit never sees it).
- Liberal parsing: bare array accepted; entries may be plain strings
  (name only); unknown fields ignored; empty/whitespace names dropped;
  errors mirror `VocabularyJSON.ParseError`.
- `export(_:)`, `template(existing:)` (with inline instructions field), and
  `agentPrompt(existing:)` for parity with vocabulary — the agent prompt
  asks for a roster with per-person context and embeds the current people.
- `Store.importPeople(_ imported: [PersonImport]) -> Int` merges by
  case-insensitive name match:
  - No match → append a new `Person(name:context:)`.
  - Match → update `context` when the imported record provides one
    (imported wins). Name casing, photo, sessions untouched.
  - Never deletes anyone.
- `PeopleListView` toolbar menu (alongside the existing + button):
  Import People… (fileImporter, same content types as vocabulary),
  Export People (ShareLink to a written template file), Share Agent Prompt.
  Import result surfaced in an alert, mirroring `VocabularyListView`.

## 4. People URL sync

New `App/Sources/PeopleSync.swift` extension on `Store`, mirroring
`VocabularySync.swift`:

- Store fields: `peopleSourceURL: String`, `peopleHeaders: [HTTPHeader]`
  (Keychain key `"peopleHeaders"`), `peopleLastSync: Date?`,
  `peopleSyncError: String?` (transient), `peopleLastSyncAttempt`
  (`@ObservationIgnored`). Persisted fields all optional.
- `syncPeopleIfConfigured()` with the same 60 s cooldown, called from the
  same `scenePhase` hook in `LuxiconApp` where
  `syncVocabularyIfConfigured()` runs.
- `syncPeople()`: https-only (same wording), header rows trimmed of
  whitespace/newlines and blank rows skipped, 15 s timeout, 2xx check,
  parse via `PeopleJSON`, then **merge via `importPeople`** — the one
  deliberate difference from vocabulary's replace semantics.
- Shared plumbing: the GitHub-404 hint and `SyncError` currently private to
  `VocabularySync.swift` are extracted into one shared helper (e.g.
  `RemoteSyncHTTP` in the app target) used by both sync extensions, so the
  hint logic isn't duplicated.
- `MyVoiceView`: "People sync" section directly below "Vocabulary sync",
  identical URL field / Request Headers disclosure / Sync Now button.
  Footer states the merge semantics: syncing adds and updates people
  (name + context) and never removes anyone; removal is manual.

## 5. Error handling

Same posture as vocabulary sync throughout: https-only with an explanatory
message, `badStatus` with the GitHub credential/permission hints, parse
errors surfaced verbatim in the section footer (people) or import alert.

## 6. Testing

- `SummarizerTests`: updated headline-prompt assertions; truncation at 120;
  user prompt contains the background block when context is provided and
  omits it entirely when all contexts are empty.
- New `PeopleJSONTests` mirroring `VocabularyJSONTests`: envelope parse,
  bare array, plain-string entries, unknown-field tolerance, empty-name
  filtering, export/template round-trip.
- Merge logic lives in `Store` (consistent with `importVocabulary`) and is
  exercised manually; `PeopleJSON` parsing is the unit-tested surface.

## Out of scope

- Photos in the people sync format.
- Propagating remote deletions (explicitly rejected).
- Regenerating existing summaries automatically after the prompt change.
