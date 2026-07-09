# Mac Sync per-session status — design

**Date:** 2026-07-09
**Status:** Approved

## Problem

Pushes from the iPhone to the Mac listener (`luxicon-mcp listen`) are
fire-and-forget: `autoPushIfEnabled` discards the `PushOutcome`, so the user
never learns whether a session actually landed on the Mac. When a push fails
(Mac asleep, wrong token, Local Network permission denied), nothing surfaces.
The user needs confirmation of success and a diagnostic error message on
failure — but only when the Mac Sync feature is actually in use.

"Mac Sync enabled" is defined as `!store.syncToken.isEmpty` — the same
condition that already gates the settings rows and the "Push All to Mac" menu
item.

## Data model

`SessionRecord` gains two optional fields (optionals decode as `nil` from
existing `store.json`, so no migration is needed):

- `lastPushDate: Date?` — timestamp of the most recent successful push.
- `lastPushError: String?` — human-readable message from the most recent
  failed push attempt; cleared on success.

Derived sync state for a `.ready` session while Mac Sync is enabled:

| State   | Condition                                | Meaning                                  |
|---------|------------------------------------------|------------------------------------------|
| synced  | `lastPushDate != nil`, `lastPushError == nil` | Last push confirmed by the listener ack |
| failed  | `lastPushError != nil`                   | Last attempt failed; message says why    |
| pending | both `nil`                               | Never attempted (e.g. pre-setup session) |

Sessions that are not `.ready`, or when Mac Sync is disabled, show no sync
state at all.

## Recording outcomes

`Store.pushToMac(_:)` (App/Sources/MacSyncService.swift) becomes the single
place outcomes are recorded: on `.success` it sets `lastPushDate = Date()` and
clears `lastPushError`; on `.failure` it sets `lastPushError` to the error
description (already human-readable via `SyncPushError.errorDescription`,
e.g. "No Mac listener found on this network. Is `luxicon-mcp listen`
running?"). Both paths `save()`. `.notConfigured` leaves state untouched.

Because auto-push, "Push All to Mac", and the new manual retry all route
through `pushToMac`, every path updates the same state with no extra
bookkeeping.

Note: `pushToMac` looks up the session in `store.sessions` by id when writing
the outcome (rather than mutating its value-copy parameter), so a session
deleted mid-push is simply skipped.

## Auto-retry on foreground

New `Store.retryFailedPushesIfEnabled()` called from `LuxiconApp` on
`scenePhase == .active`, alongside `syncVocabularyIfConfigured()`.

- Gated on `autoPushToMac` being on (and token set).
- Rate-limited with an in-memory 60-second cooldown, mirroring
  `vocabularyLastSyncAttempt`.
- Retries only sessions in the **failed** state, sequentially. Never-attempted
  (pending) sessions are deliberately excluded: enabling sync must not
  surprise-upload the whole history on next foreground. "Push All to Mac"
  remains the deliberate backfill path.

## UI

All of the following renders only when Mac Sync is enabled and the session is
`.ready`.

### Session rows (`SessionRow` in PersonDetailView.swift)

A small secondary indicator next to the existing status mark:

- synced — green (e.g. `laptopcomputer` / checkmark-badged variant)
- failed — orange exclamation variant
- pending — faint gray variant

Exact SF Symbols chosen at implementation time from what the deployment
target supports; color carries the meaning.

### Session detail (`TranscriptView` in SessionDetailView.swift)

A new "Mac Sync" section:

- **synced** — "Pushed to Mac \<relative time\>".
- **failed** — the full error message in red, plus a **Retry Push** button.
- **pending** — "Not pushed yet", plus a **Push to Mac** button.

Retry/push buttons call `pushToMac` for that session and show a progress
indicator while in flight; the section re-renders from the recorded outcome.

## Out of scope

- Invalidating sync state when a transcript is edited after a successful push
  (speaker rename). Summary regeneration already re-triggers auto-push.
- A global toolbar sync indicator.
- Persisting a retry queue; state on the sessions *is* the queue.

## Testing

The app target has no unit-test bundle (Tests/ covers LuxiconKit, where the
push transport is already exercised by SyncTests). Verification is:
`swift build` for the Kit, Xcode build for the app, and an on-device check
(Release build + devicectl install) exercising success, listener-down
failure, and retry.
