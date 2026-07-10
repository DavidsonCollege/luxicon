# Mac sync installer share link — design

## Goal

Let a user hand off the Mac listener installer to their Mac from inside the iOS
app. Add a share-sheet control near the "Mac sync" settings so the user can
AirDrop / Message / Mail a link to the installer instead of typing a URL on the
Mac by hand.

## Scope

One `ShareLink` row added to the existing "Mac sync" `Section` in
`App/Sources/Views/MyVoiceView.swift`. No new state, no persistence changes, no
network calls beyond opening the system share sheet with a static URL.

## Design

- **Link target:** `https://github.com/DavidsonCollege/luxicon/releases` — the
  GitHub Releases page hosting the prebuilt `LuxiconListener-<version>.pkg`.
  This is the documented non-developer install path (download pkg,
  double-click), per `docs/sync.md`.
- **Placement:** first row of the "Mac sync" section, above the pairing-token
  field. This matches the real setup order: install the listener on the Mac →
  it prints a pairing token → enter that token below.
- **Idiom:** SwiftUI `ShareLink`, matching the app's existing share pattern
  (`SessionDetailView`, `VocabularyListView`, etc.). Because the target is a
  plain web URL, no temp-file write is needed:

  ```swift
  ShareLink(item: URL(string: "https://github.com/DavidsonCollege/luxicon/releases")!) {
      Label("Send installer link to your Mac", systemImage: "square.and.arrow.up")
  }
  ```
- **Copy:** the section footer gains a short sentence pointing at the link so
  the row's purpose reads clearly.

## Non-goals (YAGNI)

- No `SharePreview` customization.
- No version-pinned pkg asset URL.
- No new settings or toggles.

## Testing

App-only UI change; there is no app test bundle (tests cover LuxiconKit only).
Verified by building the app.
