# Giving Screen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A sheet framing Luxicon as a free, open-source service of Davidson College with a link out to davidson.edu/giving, reachable from a credit footer on the root people list and a section in My Voice settings.

**Architecture:** One new SwiftUI view (`AboutGivingView`) presented as a sheet from two existing screens. Two new asset-catalog entries (`AppIconLarge` imageset reusing the app icon PNG, `DavidsonRed` colorset). No model, Store, or persistence changes — the screen is stateless.

**Tech Stack:** SwiftUI (iOS 18 target, Swift 6), xcodegen-generated Xcode project.

**Spec:** `docs/superpowers/specs/2026-07-10-giving-screen-design.md`

## Global Constraints

- **No tests exist for the app target** (LuxiconKit tests don't cover App/). Verification per task is a successful `xcodebuild` build; final verification is on-device.
- **`cd App && xcodegen generate` is REQUIRED after adding any source file** (Task 2). Asset-only changes (Task 1) do not need it. Never edit `Luxicon.xcodeproj` by hand.
- Build command (from repo root):
  `cd App && xcodebuild -project Luxicon.xcodeproj -scheme Luxicon -destination 'generic/platform=iOS' -configuration Release -allowProvisioningUpdates build`
  Expected: `** BUILD SUCCEEDED **`
- **Donation link must open outside the app** (App Store Guideline 3.2.1): `openURL` / `Link` to Safari, never an in-app web view.
- **No new network calls** beyond the two user-initiated link-outs (README privacy posture is load-bearing App Store copy).
- **Do not touch `Store.Persisted` or `SessionRecord`.**
- Exact copy strings and URLs are given verbatim in the tasks; do not paraphrase them. The italicized mission line is verbatim from Davidson's Statement of Purpose.
- Colors: `DavidsonRed` = `#AC1A2F` light / `#E06A7C` dark. Only Davidson-branded elements use it; everything else keeps the default tint.

---

### Task 1: Asset catalog entries (AppIconLarge, DavidsonRed)

**Files:**
- Create: `App/Assets.xcassets/AppIconLarge.imageset/Contents.json`
- Create: `App/Assets.xcassets/AppIconLarge.imageset/AppIconLarge.png` (copy of existing icon)
- Create: `App/Assets.xcassets/DavidsonRed.colorset/Contents.json`

**Interfaces:**
- Produces: `Image("AppIconLarge")` and `Color("DavidsonRed")` usable from any app-target SwiftUI view (Tasks 2–4 use both names exactly).

- [ ] **Step 1: Create the AppIconLarge imageset**

The `AppIcon` icon asset can't be loaded at arbitrary sizes from code, so the same PNG gets a plain imageset:

```bash
mkdir -p App/Assets.xcassets/AppIconLarge.imageset
cp App/Assets.xcassets/AppIcon.appiconset/AppIcon.png App/Assets.xcassets/AppIconLarge.imageset/AppIconLarge.png
```

Write `App/Assets.xcassets/AppIconLarge.imageset/Contents.json`:

```json
{
  "images" : [
    {
      "filename" : "AppIconLarge.png",
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

- [ ] **Step 2: Create the DavidsonRed colorset**

Write `App/Assets.xcassets/DavidsonRed.colorset/Contents.json` (#AC1A2F light, #E06A7C dark — the dark variant is lightened for contrast on dark grounds):

```json
{
  "colors" : [
    {
      "color" : {
        "color-space" : "srgb",
        "components" : {
          "alpha" : "1.000",
          "blue" : "0x2F",
          "green" : "0x1A",
          "red" : "0xAC"
        }
      },
      "idiom" : "universal"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "dark"
        }
      ],
      "color" : {
        "color-space" : "srgb",
        "components" : {
          "alpha" : "1.000",
          "blue" : "0x7C",
          "green" : "0x6A",
          "red" : "0xE0"
        }
      },
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

- [ ] **Step 3: Build to verify the catalog compiles**

No xcodegen needed — `Assets.xcassets` is already a source in `project.yml`.

Run: `cd App && xcodebuild -project Luxicon.xcodeproj -scheme Luxicon -destination 'generic/platform=iOS' -configuration Release -allowProvisioningUpdates build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add App/Assets.xcassets/AppIconLarge.imageset App/Assets.xcassets/DavidsonRed.colorset
git commit -m "App: AppIconLarge imageset and DavidsonRed color assets"
```

---

### Task 2: AboutGivingView

**Files:**
- Create: `App/Sources/Views/AboutGivingView.swift`
- Modify: `App/Luxicon.xcodeproj` (regenerated via xcodegen, never by hand)

**Interfaces:**
- Consumes: `Image("AppIconLarge")`, `Color("DavidsonRed")` from Task 1.
- Produces: `struct AboutGivingView: View` with a no-argument initializer, designed for `.sheet` presentation (Tasks 3 and 4 present it exactly as `AboutGivingView()`).

- [ ] **Step 1: Write the view**

Create `App/Sources/Views/AboutGivingView.swift`:

```swift
import SwiftUI

/// Frames Luxicon as a free, open-source service of Davidson College and
/// invites a gift to the college. App Store Guideline 3.2.1 requires the
/// donation to happen outside the app, so the button opens Safari.
struct AboutGivingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Close")
            }
            .padding(.top, 16)

            Spacer()

            Image("AppIconLarge")
                .resizable()
                .frame(width: 116, height: 116)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .shadow(color: Color("DavidsonRed").opacity(0.35), radius: 14, y: 8)

            Text("Luxicon")
                .font(.title2.bold())
                .padding(.top, 16)
            Text("A service of Davidson College")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color("DavidsonRed"))
                .padding(.top, 2)

            VStack(spacing: 12) {
                Text("Luxicon is free and open source, built by Davidson College Technology & Innovation. Everything — recording, transcription, summaries — stays on your device.")
                Text("If you like what you see, consider a gift to Davidson. Giving sustains the college's primary purpose: *developing humane instincts and disciplined and creative minds for lives of leadership and service.*")
            }
            .font(.callout)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .padding(.top, 20)

            Spacer()

            Button {
                openURL(URL(string: "https://www.davidson.edu/giving")!)
            } label: {
                Text("Give to Davidson")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color("DavidsonRed"))

            Text("Opens davidson.edu/giving in Safari")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 8)

            Link("View the source on GitHub",
                 destination: URL(string: "https://github.com/DavidsonCollege/luxicon")!)
                .font(.footnote)
                .tint(Color("DavidsonRed"))
                .padding(.top, 14)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
        .presentationDragIndicator(.visible)
    }
}
```

Note the two body-copy strings: SwiftUI `Text` renders the `*…*` markdown span as italics — keep the asterisks.

- [ ] **Step 2: Regenerate the project**

Run: `cd App && xcodegen generate`
Expected: `Created project at .../Luxicon.xcodeproj` (required — the project won't see the new file otherwise).

- [ ] **Step 3: Build**

Run: `cd App && xcodebuild -project Luxicon.xcodeproj -scheme Luxicon -destination 'generic/platform=iOS' -configuration Release -allowProvisioningUpdates build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add App/Sources/Views/AboutGivingView.swift App/Luxicon.xcodeproj
git commit -m "App: AboutGivingView giving screen"
```

---

### Task 3: Settings entry point (My Voice form)

**Files:**
- Modify: `App/Sources/Views/MyVoiceView.swift` (Mac sync section ends ~line 153; `.navigationTitle("My Voice")` ~line 159)

**Interfaces:**
- Consumes: `AboutGivingView()` from Task 2, assets from Task 1.

- [ ] **Step 1: Add state, section, and sheet**

In `MyVoiceView`, add alongside the other `@State` properties (after `@State private var showRemoveModelConfirmation = false`):

```swift
@State private var showingAboutGiving = false
```

Add a new section **after the Mac sync section's closing `}` (the one whose footer mentions `luxicon-mcp listen`) and before the `if let errorMessage` block**:

```swift
Section {
    Button {
        showingAboutGiving = true
    } label: {
        HStack(spacing: 12) {
            Image("AppIconLarge")
                .resizable()
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text("About Luxicon & Giving")
                .foregroundStyle(.primary)
        }
    }
} header: {
    Text("Davidson College")
} footer: {
    Text("Luxicon is a free, open-source service of Davidson College.")
}
```

Attach the sheet to the `Form`, directly after `.navigationTitle("My Voice")`:

```swift
.sheet(isPresented: $showingAboutGiving) {
    AboutGivingView()
}
```

- [ ] **Step 2: Build**

Run: `cd App && xcodebuild -project Luxicon.xcodeproj -scheme Luxicon -destination 'generic/platform=iOS' -configuration Release -allowProvisioningUpdates build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add App/Sources/Views/MyVoiceView.swift
git commit -m "App: Davidson College section in settings opens the giving screen"
```

---

### Task 4: Root list credit footer (both states)

**Files:**
- Modify: `App/Sources/Views/PeopleListView.swift` (empty state ~lines 18–26, people list ~lines 28–61, modifier chain after `.navigationTitle("Luxicon")` ~line 64)

**Interfaces:**
- Consumes: `AboutGivingView()` from Task 2, assets from Task 1.

- [ ] **Step 1: Add state and the credit view**

In `PeopleListView`, add alongside the other `@State` properties (after `@State private var importResult: String?`):

```swift
@State private var showingAboutGiving = false
```

Add a private computed view at the bottom of the struct (next to `writePeopleFile()`):

```swift
/// Credit line that opens the giving screen — shown at the bottom of the
/// roster and under the empty state, so the Davidson framing is on the
/// home screen in both cases.
private var davidsonCredit: some View {
    Button {
        showingAboutGiving = true
    } label: {
        VStack(spacing: 2) {
            Image("AppIconLarge")
                .resizable()
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.bottom, 4)
            Text("A free, open-source service of Davidson College")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Learn more & give ›")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color("DavidsonRed"))
        }
        .frame(maxWidth: .infinity)
    }
    .buttonStyle(.plain)
}
```

- [ ] **Step 2: Show it in both root states**

**Populated list:** inside the `List`, after the `ForEach(store.people)`'s `.onDelete { … }` closing brace, add a final section:

```swift
Section {
    davidsonCredit
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .padding(.top, 8)
}
```

**Empty state:** wrap the existing `ContentUnavailableView { … }` in a `VStack` with the credit beneath it:

```swift
VStack {
    ContentUnavailableView {
        Label("No people yet", systemImage: "person.2")
    } description: {
        Text("Add the people you hold 1-on-1s with. Everything is recorded, transcribed, and stored on this device only.")
    } actions: {
        Button("Add Person") { showingAddPerson = true }
            .buttonStyle(.borderedProminent)
    }
    davidsonCredit
        .padding(.bottom, 32)
}
```

(The `ContentUnavailableView` content is unchanged — only the wrapper and credit are new.)

- [ ] **Step 3: Attach the sheet**

In the modifier chain, next to the existing `.sheet(isPresented: $coordinator.quickRecordPickerShown)`, add:

```swift
.sheet(isPresented: $showingAboutGiving) {
    AboutGivingView()
}
```

- [ ] **Step 4: Build**

Run: `cd App && xcodebuild -project Luxicon.xcodeproj -scheme Luxicon -destination 'generic/platform=iOS' -configuration Release -allowProvisioningUpdates build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add App/Sources/Views/PeopleListView.swift
git commit -m "App: Davidson College credit on the root screen opens the giving screen"
```

---

### Task 5: On-device verification

**Files:** none (verification only)

- [ ] **Step 1: Install the Release build on the phone**

The Release build from Task 4 is already in DerivedData. Install it:

```bash
xcrun devicectl list devices
xcrun devicectl device install app --device <id> \
  ~/Library/Developer/Xcode/DerivedData/Luxicon-*/Build/Products/Release-iphoneos/Luxicon.app
```

(Release, not Debug — Debug builds depend on the stub-executor dylib and won't launch from a direct install.)

- [ ] **Step 2: Check each flow on the device**

- Root list shows the credit under the roster; tapping it opens the sheet.
- My Voice → bottom "Davidson College" section row opens the same sheet.
- Sheet shows the enlarged icon, tagline, both paragraphs (mission line italicized), red Give button.
- "Give to Davidson" opens davidson.edu/giving **in Safari** (app backgrounds).
- "View the source on GitHub" opens the repo in Safari.
- Sheet dismisses by swipe and by the ✕ button.
- Dark mode: DavidsonRed elements stay legible (lightened variant).
- Optional: verify the empty state by temporarily filtering, or skip if the roster is populated — the code path is identical.

- [ ] **Step 3: Report results**

No commit — report any failures with what was observed; do not claim success without having run the flows.
