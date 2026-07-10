# Apple Intelligence as a selectable summarization engine

**Date:** 2026-07-10
**Status:** Approved

## Goal

Add Apple Intelligence (the FoundationModels on-device model) as a second
summarization engine alongside Gemma 4 E2B. Users who enable AI Summaries
choose their engine — Apple Intelligence (instant, no download, iOS 26+ on
eligible devices, with iOS-version-based disclaimers) or Gemma 4 E2B (today's
2.5 GB download) — and can switch later. Long transcripts are handled by
split summarization (chunk → section notes → merge) on **both** engines,
replacing the current head/tail trim.

Both engines run fully on-device; the README/App Store privacy posture is
unchanged.

## Decisions made during brainstorming

- **Engine UX:** choose at enable time, switchable later via a picker in the
  AI Summaries section of My Voice.
- **Long transcripts:** split summarization at the context boundary, applied
  to both engines (not a trim, not Apple-only).
- **Guardrail refusals:** clear error on the session with manual recourse
  (Regenerate button; switch engines in My Voice). No silent auto-fallback.
- **Architecture:** extend the existing `SummaryChat` seam. Same prompts and
  HEADLINE/SUMMARY parsing for both engines. Not adopting Apple's WWDC26
  `LanguageModel` protocol as the abstraction, and not using `@Generable`
  guided generation, in this iteration.

## 1. Core backend (LuxiconKit)

### SummaryChat goes async

`SummaryChat.generate(messages:sampling:)` becomes `async throws -> String`.
A synchronous method satisfies an async protocol requirement, so the existing
`Qwen35MLXChat` / `Gemma4Chat` conformances (empty extensions in
`MeetingSummarizer.swift`) keep working unchanged. Call sites
(`MeetingSummarizer.summarize`, `refineLabel`, `SummaryService`, CLI) adopt
`await`.

### AppleIntelligenceChat

New file `Sources/LuxiconKit/AppleIntelligenceChat.swift`:

- `@available(iOS 26.0, macOS 26.0, *)` class conforming to `SummaryChat`,
  wrapping FoundationModels' `LanguageModelSession`.
- Built on `SystemLanguageModel(guardrails: .permissiveContentTransformations)`
  — the relaxed mode intended for summarization/transformation of
  user-provided content.
- Maps `ChatMessage` roles: system message → session `Instructions`, user
  message → the prompt. Maps `ChatSamplingConfig` (temperature, maxTokens) →
  `GenerationOptions`.
- Creates a fresh session per `generate` call (isolated task; no chat history).
- Entire file wrapped in `#if canImport(FoundationModels)` so the package
  builds on toolchains without the framework.

### Backend enum

`MeetingSummarizer.Backend` gains `.appleIntelligence`:

- `load(backend:)` for Apple: check `SystemLanguageModel.availability`; throw
  a descriptive error per unavailability reason (device not eligible, Apple
  Intelligence not enabled, model not ready, OS too old). No download, no
  progress stages.
- `isModelDownloaded(.appleIntelligence)` ≙ availability == `.available`
  (the OS manages the weights).
- `modelCacheDirectory(for: .appleIntelligence)` throws (no app-owned model
  directory exists for this backend). Call sites already use `try?`.

## 2. Split summarization (both engines)

Replaces the transcript head 65% + tail 30% clip. Context-entry clipping
(2,000 chars each) stays.

### Per-pass transcript budget

Each backend exposes a per-pass transcript **character budget**:

- **Gemma:** 20,000 chars (today's number — single-pass behavior is
  byte-identical for meetings that fit).
- **Apple Intelligence:** derived at runtime. Where `contextSize` /
  `tokenCount(for:)` exist (iOS/macOS 26.4+), measure the actual prompt
  overhead and window; otherwise estimate conservatively at ~3.5 chars/token.
  Expected results: ~9,000 chars/pass on iOS 26 (4,096-token window minus
  prompt overhead and 700 output tokens); ~23,000 chars/pass on iOS 27
  (8,192-token window) — current transcripts fit in one pass.

### Pipeline (pure logic in MeetingSummarizer, unit-testable)

1. **Fits the budget → single pass.** Exactly today's system/user prompt and
   HEADLINE/SUMMARY parse. No behavior change.
2. **Over budget → chunk.** Split at speaker-turn boundaries into roughly
   equal chunks, each ≤ budget. Never split mid-turn.
3. **Section-notes pass per chunk.** Prompt frames it as "Part i of N of a
   longer meeting"; output is grounded bullet notes (topics, decisions,
   action items with owners), max ~400 tokens, not the final format. The
   Reference (participant context) block is included only in the merge pass,
   not per-chunk (keeps chunks lean; fencing rules unchanged).
4. **Merge pass.** Meeting metadata + Reference block + the N section notes →
   the existing final format (HEADLINE + structured SUMMARY), parsed by the
   existing parser. Section notes are bounded (N × ~400 tokens) and each is
   defensively clipped so the merge input always fits the budget.

Empty/thin gating (`isEmpty`, `isTooThin`), prompt-injection fencing, output
parsing, and the CLI-only `refineLabel` second-pass experiment are unchanged.

## 3. App: engine choice, enable flow, disclaimers

### Persistence

- New `SummaryEngine: String, Codable` enum: `appleIntelligence`, `gemma`.
- New optional persisted field `Store.summaryEngine: SummaryEngine?`
  (back-compat: optional, never repurposes existing keys).
- Migration in `load()`: `aiSummariesEnabled == true && summaryEngine == nil`
  → `.gemma` (existing users keep exactly what they have).

### SummaryService

- `static let backend` hardcode is removed; the actor resolves the backend
  from the store's engine at load time.
- Switching engines unloads the resident model and loads the new backend on
  next use (or immediately during the switch flow for Gemma download).

### Enable flow (My Voice → AI Summaries)

The "Enable AI Summaries…" confirmation dialog offers up to two actions:

- **"Use Apple Intelligence"** — shown only when availability is
  `.available`. Enables instantly; sets `summaryEngine = .appleIntelligence`;
  no download, no disk-space warning.
- **"Download 2.5 GB & Use Gemma"** — today's flow unchanged (disk-space
  disclosure, progress stages, flip-back on failure).

The dialog message notes both engines run entirely on this phone.

### Engine picker (after enabling)

The AI Summaries section gains a Picker (Apple Intelligence / Gemma 4 E2B):

- Apple row disabled with an inline reason when unavailable.
- Switching to Gemma without weights on disk triggers the download with
  existing progress UI; on failure the engine reverts to the previous value
  (same flip-back philosophy as enable).
- Switching to Apple Intelligence is instant (availability re-checked).
- "Turn Off & Remove Model" offers the remove-model option only when Gemma
  weights exist on disk; otherwise just "Turn Off".

### Disclaimers (footer / inline, by availability and iOS version)

- iOS < 26 or device not eligible: "Apple Intelligence requires iOS 26 on
  iPhone 15 Pro or later — Gemma works on this phone."
- Apple Intelligence disabled in system Settings: "Turn on Apple Intelligence
  in Settings to use it here."
- Model not ready: "Apple Intelligence is preparing — try again shortly."
- iOS 26.x with Apple engine active: "Long meetings are summarized in
  sections and stitched together. iOS 27 summarizes longer meetings in one
  pass."
- iOS 27+: no caveat.

## 4. Error handling

Today `startSummarizing`'s catch block is silent. New transient (not
persisted) state `processing.summarizeError: [UUID: String]`:

- **Cancellation** (backgrounding): silent, as today.
- **Guardrail refusal** (`guardrailViolation`): "Apple Intelligence declined
  to summarize this conversation. You can regenerate or switch engines in
  My Voice."
- **Availability lost** (user turned Apple Intelligence off after choosing
  it): "Apple Intelligence is unavailable. Turn it on in Settings or switch
  engines in My Voice."
- **Other errors:** generic failure message.

Displayed in `SessionDetailView.summarySection` near the Generate/Regenerate
button; cleared when a retry starts.

## 5. CLI harness

`luxicon-cli summarize` gains:

- `--backend apple` — runtime macOS 26 availability check with a clear error
  message when unavailable. Enables A/B of the same transcript across
  `gemma4` and `apple` (the established prompt-verification workflow).
- `--chunk-chars <n>` — debug override of the per-pass budget so split
  summarization can be exercised on short transcripts.

## 6. Testing

Tests remain LuxiconKit-only, offline, no model downloads:

- Chunk splitting: turn-boundary integrity, budget respected, single-pass
  when the transcript fits, roughly-equal chunk sizes.
- Prompt assembly: section-notes prompt ("Part i of N"), merge prompt
  (metadata + Reference + notes), Reference fencing present only in
  merge/single-pass prompts.
- Multi-pass orchestration via a scripted mock `SummaryChat` (records the
  prompts it receives, returns canned notes/summaries) — now trivial with the
  async protocol.
- Existing parse/gating tests unchanged.
- No FoundationModels calls in tests (availability-dependent, not offline-safe).

## 7. Out of scope / unchanged

- Sync wire protocol, `SessionSummary` / `listLabel` storage shapes, export
  formats.
- Auto-summarize trigger and the `aiSummariesEnabled` gate.
- Qwen legacy-model cleanup path.
- `@Generable` guided generation and Apple's `LanguageModel` protocol
  (possible future iteration).
- Private Cloud Compute (off-device; conflicts with the on-device privacy
  posture).

## Risks

- **Guardrail refusal rate on real 1:1s is unknown.** Mitigated by
  `.permissiveContentTransformations`, the visible error path, and the Gemma
  escape hatch. Validate early with real transcripts via
  `luxicon-cli summarize --backend apple` on a macOS 26 machine.
- **Apple-model summary quality vs Gemma is unverified.** The prompts were
  tuned against Gemma's habits; harness A/B before shipping.
- **Token-budget estimation on pre-26.4 systems** is heuristic; the ~3.5
  chars/token estimate must stay conservative to avoid context overflows.
