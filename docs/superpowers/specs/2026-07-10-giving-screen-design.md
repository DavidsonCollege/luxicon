# Giving Screen — Design

**Date:** 2026-07-10
**Status:** Approved (mockups: claude.ai/code artifact "Luxicon — Giving Screen Mockups")

## Goal

A screen that frames Luxicon as a free, open-source service of Davidson College
and invites people who like it to give to the college, linking out to
<https://www.davidson.edu/giving>. It shows an enlarged version of the app icon.

## Presentation

One SwiftUI view, `AboutGivingView` (new file
`App/Sources/Views/AboutGivingView.swift`), presented as a **sheet** from both
entry points. It is an occasional interstitial, not a place in the app's
hierarchy — swipe down (or tap the close button) returns you to where you were.

### Content, top to bottom (centered)

1. **Enlarged app icon** — ~116 pt, iOS icon corner rounding, soft red shadow.
   The `AppIcon` asset can't be loaded at large sizes from code, so add a
   second imageset `AppIconLarge` to `App/Assets.xcassets` reusing the same
   PNG. (Asset-only change — no `xcodegen generate` needed for it; the new
   Swift file does require regenerating the project.)
2. **Title:** `Luxicon`
3. **Tagline** (Davidson red): `A service of Davidson College`
4. **Body copy:**
   > Luxicon is free and open source, built by Davidson College Technology &
   > Innovation. Everything — recording, transcription, summaries — stays on
   > your device.
   >
   > If you like what you see, consider a gift to Davidson. Giving sustains
   > the college's primary purpose: *developing humane instincts and
   > disciplined and creative minds for lives of leadership and service.*

   The italicized line is verbatim from Davidson's Statement of Purpose,
   trimmed to read as part of the sentence.
5. **Primary button** (prominent, Davidson red): `Give to Davidson` — opens
   `https://www.davidson.edu/giving` via `openURL` (Safari, outside the app).
6. **Caption** under the button: `Opens davidson.edu/giving in Safari`
7. **Secondary link:** `View the source on GitHub` — opens
   `https://github.com/DavidsonCollege/luxicon`.

## Entry points (two, both open the same sheet)

### 1. Root list footer (the front door)

A quiet credit at the bottom of `PeopleListView`'s list: small app icon
(~34 pt), line 1 `A free, open-source service of Davidson College`
(secondary color), line 2 `Learn more & give ›` (Davidson red/tint). The whole
block is tappable.

- **With people:** rendered after the people rows (list footer — scrolls with
  the list, not pinned).
- **Empty state:** also shown beneath the existing `ContentUnavailableView`
  so first-launch users see the framing too.

### 2. Settings section (the permanent address)

A final section in `MyVoiceView`'s form, after Mac sync:

- Header: `Davidson College`
- Row: small app icon + `About Luxicon & Giving` → presents the sheet
- Footer: `Luxicon is a free, open-source service of Davidson College.`

Rationale: the root footer is what actually gets the message seen (every
launch, reads as a maker's credit, no new chrome); the settings row makes the
screen findable later ("where was that giving link?"). A third option — the
root toolbar's ⋯ menu — was considered and rejected as too buried.

## Color

The app has no `AccentColor` asset — its real tint is the iOS default blue
(the mockups' red chrome overstated this). Add a `DavidsonRed` color asset
(#AC1A2F, dark-mode variant lightened for contrast) used only for the
Davidson-branded elements: the sheet's tagline and Give button, and the root
footer's `Learn more & give ›` line. Everything else keeps the standard tint.

## Constraints

- **App Store Guideline 3.2.1:** charitable donations must happen outside the
  app. The button links out to Safari; no in-app web view or payment for the
  donation itself.
- **Privacy posture (README, load-bearing):** no new network calls. The only
  network touch is the user-initiated Safari link, consistent with the
  "everything on-device" copy this screen itself restates.
- **No persistence changes** — the screen is stateless; nothing added to
  `Store.Persisted`.
- **Testing:** LuxiconKit tests don't apply (app-only change). Verify by
  building for device and checking both entry points and both root states
  (empty and populated).
