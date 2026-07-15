# Open-Source Hygiene Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Verified MIT license posture with full dependency attribution (repo file + in-app screen + installer), plus CONTRIBUTING, code of conduct, issue/PR templates, and README/metadata polish.

**Architecture:** A maintainer-run script (`scripts/generate-notices.sh`) reads `Package.resolved`, fetches each dependency's license via the GitHub API, gates on copyleft, and emits two checked-in artifacts: `THIRD-PARTY-NOTICES.md` (repo root, also staged into the Mac listener pkg) and `App/Resources/acknowledgements.json` (bundled into the iOS app and rendered by a new `AcknowledgementsView`). Model-weight credits are hand-maintained in `scripts/model-acknowledgements.json` and merged in by the script. Community docs are static files.

**Tech Stack:** bash + python3 + `gh` (script), SwiftUI (one new view), GitHub issue forms (YAML).

**Spec:** `docs/superpowers/specs/2026-07-14-open-source-hygiene-design.md`

## Global Constraints

- Never edit `App/Luxicon.xcodeproj` — it is generated. Change `App/project.yml` and run `cd App && xcodegen generate`.
- No new network calls in the app. The acknowledgements screen loads a **bundled** JSON only; row taps use `Link` (user-initiated Safari link-out, same pattern as `AboutGivingView`).
- `swift test` must stay offline and pass untouched (no LuxiconKit code changes in this plan).
- The generator script is a **maintainer tool** — never wired into any build.
- License stays MIT **only if** Task 1's audit gate passes (no GPL/LGPL/AGPL/MPL/EUPL/CDDL, nothing unresolvable). If the gate fails: STOP the plan and report to the maintainer.
- Copy style: the project says "1-on-1", "on-device", "Mac sync" — match existing README/app voice.
- Commit after every task with a conventional-commit style message matching repo history (`App:`, `docs:`, `scripts:` prefixes are all in use; follow the examples given per task).

---

### Task 1: Notices generator script + license audit

**Files:**
- Create: `scripts/generate-notices.sh`
- Create: `scripts/model-acknowledgements.json`
- Create (generated): `THIRD-PARTY-NOTICES.md`
- Create (generated): `App/Resources/acknowledgements.json`

**Interfaces:**
- Consumes: `Package.resolved` (repo root), GitHub API via authenticated `gh`.
- Produces: `THIRD-PARTY-NOTICES.md` at repo root (Task 3 stages it into the pkg; Task 7 links it from the README). `App/Resources/acknowledgements.json` with shape `{"packages": [{"name","version","license","url","copyright"}], "models": [same shape]}` — Task 2's `AcknowledgementsView` decodes exactly this.

- [ ] **Step 1: Verify the exact model list before hand-writing credits**

The README credits three model families (Parakeet TDT: CC-BY-4.0, Pyannote segmentation: MIT, WeSpeaker: Apache-2.0) plus "a small live-caption model". Confirm the exact Hugging Face repo IDs speech-swift downloads:

```bash
ls .build/checkouts/speech-swift >/dev/null 2>&1 || swift package resolve
grep -rhoE '"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+"' .build/checkouts/speech-swift/Sources --include='*.swift' \
  | grep -iE 'parakeet|pyannote|wespeaker|whisper|speaker|segment|kokoro|silero' | sort -u
```

Expected: a short list of HF repo IDs (e.g. `nvidia/parakeet-tdt-0.6b-v2`, a pyannote segmentation repo, a WeSpeaker embedding repo, possibly a streaming/caption model). Use ONLY the models Luxicon actually invokes — the pipeline products are `SpeechVAD`, `ParakeetASR`, `ParakeetStreamingASR`, `AudioCommon` (see `Package.swift`). If a repo ID's license is not obvious, check its Hugging Face page. Adjust Step 2's JSON to match reality; keep the README's license claims consistent (if you find a discrepancy, note it for Task 7's README pass).

- [ ] **Step 2: Write the hand-maintained model credits file**

Create `scripts/model-acknowledgements.json` (correct the `url`/`name` fields to what Step 1 found; keep the structure identical):

```json
{
  "models": [
    {
      "name": "NVIDIA Parakeet TDT 0.6B",
      "version": null,
      "license": "CC-BY-4.0",
      "url": "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2",
      "copyright": "© NVIDIA Corporation. Converted to CoreML by the speech-swift project."
    },
    {
      "name": "Pyannote segmentation 3.0",
      "version": null,
      "license": "MIT",
      "url": "https://huggingface.co/pyannote/segmentation-3.0",
      "copyright": "© pyannote (Hervé Bredin)"
    },
    {
      "name": "WeSpeaker ResNet34 speaker embeddings",
      "version": null,
      "license": "Apache-2.0",
      "url": "https://huggingface.co/pyannote/wespeaker-voxceleb-resnet34-LM",
      "copyright": "© WeSpeaker developers"
    }
  ]
}
```

- [ ] **Step 3: Write `scripts/generate-notices.sh`**

```bash
#!/bin/bash
# Regenerate THIRD-PARTY-NOTICES.md and App/Resources/acknowledgements.json
# from Package.resolved (plus scripts/model-acknowledgements.json for model
# weights). Maintainer tool: run after any dependency change, review the
# diff, commit the outputs. Requires network and an authenticated `gh`.
# Exits nonzero — and writes nothing — on copyleft or unresolvable licenses.
set -euo pipefail
cd "$(dirname "$0")/.."

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

python3 - > "$TMP/pins.tsv" <<'PY'
import json
for p in json.load(open("Package.resolved"))["pins"]:
    url = p["location"].removesuffix(".git")
    ver = p["state"].get("version") or p["state"].get("revision", "")[:12]
    print(f'{p["identity"]}\t{url}\t{ver}')
PY

unresolved=0
while IFS=$'\t' read -r identity url version; do
    path="${url#https://github.com/}"
    # /license reports the default branch, not the pinned ref; acceptable
    # for an audit doc — licenses effectively never change between pins.
    if ! gh api "repos/$path/license" > "$TMP/$identity.license.json" 2>/dev/null; then
        echo "UNRESOLVED: $identity ($url)" >&2
        unresolved=1
        continue
    fi
    for f in NOTICE NOTICE.txt; do
        if gh api "repos/$path/contents/$f" --jq .content 2>/dev/null \
             | base64 -d > "$TMP/$identity.notice" 2>/dev/null \
           && [ -s "$TMP/$identity.notice" ]; then
            break
        fi
        rm -f "$TMP/$identity.notice"
    done
done < "$TMP/pins.tsv"
if [ "$unresolved" -ne 0 ]; then
    echo "error: could not fetch licenses above — resolve by hand, then rerun." >&2
    exit 1
fi

python3 - "$TMP" <<'PY'
import base64, json, pathlib, sys

tmp = pathlib.Path(sys.argv[1])
pins = [l.split("\t") for l in (tmp / "pins.tsv").read_text().splitlines()]

COPYLEFT = ("GPL", "LGPL", "AGPL", "MPL", "EUPL", "CDDL")
entries = []
for identity, url, version in pins:
    info = json.loads((tmp / f"{identity}.license.json").read_text())
    spdx = (info.get("license") or {}).get("spdx_id") or "UNKNOWN"
    text = base64.b64decode(info["content"]).decode("utf-8", "replace")
    cop = next((l.strip() for l in text.splitlines()
                if "copyright" in l.lower() and any(c.isdigit() for c in l)), None)
    notice_file = tmp / f"{identity}.notice"
    entries.append({
        "name": identity, "version": version, "license": spdx, "url": url,
        "copyright": cop,
        "notice": notice_file.read_text() if notice_file.exists() else None,
        "text": text,
    })

copyleft = [e["name"] for e in entries
            if any(e["license"].upper().startswith(c) for c in COPYLEFT)]
if copyleft:
    sys.exit(f"COPYLEFT FOUND — stop and report to the maintainer: {copyleft}")
unknown = [e["name"] for e in entries
           if e["license"] in ("UNKNOWN", "NOASSERTION", "OTHER")]
if unknown:
    sys.exit(f"Licenses needing hand review (not auto-classifiable): {unknown}")

entries.sort(key=lambda e: e["name"])
models = json.loads(pathlib.Path("scripts/model-acknowledgements.json").read_text())["models"]

out = [
    "# Third-party notices",
    "",
    "Luxicon is MIT-licensed (see LICENSE). It depends on the open-source",
    "packages and model weights below. This file is generated by",
    "`scripts/generate-notices.sh` — do not edit the package sections by",
    "hand; model credits live in `scripts/model-acknowledgements.json`.",
    "",
    "## Model weights",
    "",
    "Downloaded from Hugging Face on first use, run entirely on-device:",
    "",
]
for m in models:
    out.append(f"- **{m['name']}** — {m['license']} — {m['copyright']} — <{m['url']}>")
out += ["", "## Swift packages", ""]
for e in entries:
    out.append(f"### {e['name']} {e['version']}")
    out.append("")
    out.append(f"- License: {e['license']}")
    if e["copyright"]:
        out.append(f"- {e['copyright']}")
    out.append(f"- <{e['url']}>")
    out.append("")
    if e["notice"]:
        out += ["Upstream NOTICE file:", "", "```",
                e["notice"].rstrip(), "```", ""]
out += [
    "## License texts",
    "",
    "Full text of each license above, reproduced once per license type.",
    "The copyright lines in each package's section above apply to that",
    "package's copy.",
    "",
]
seen = {}
for e in entries:
    seen.setdefault(e["license"], e["text"])
for spdx in sorted(seen):
    out += [f"### {spdx}", "", "```", seen[spdx].rstrip(), "```", ""]

pathlib.Path("THIRD-PARTY-NOTICES.md").write_text("\n".join(out) + "\n")

pathlib.Path("App/Resources").mkdir(parents=True, exist_ok=True)
ack = {
    "packages": [{k: e[k] for k in ("name", "version", "license", "url", "copyright")}
                 for e in entries],
    "models": models,
}
pathlib.Path("App/Resources/acknowledgements.json").write_text(
    json.dumps(ack, indent=2, ensure_ascii=False) + "\n")

print(f"Wrote THIRD-PARTY-NOTICES.md ({len(entries)} packages, {len(models)} models)")
print("Wrote App/Resources/acknowledgements.json")
PY
```

```bash
chmod +x scripts/generate-notices.sh
```

- [ ] **Step 4: Run it — this IS the audit**

```bash
scripts/generate-notices.sh
```

Expected: `Wrote THIRD-PARTY-NOTICES.md (38 packages, 3 models)` (counts may vary slightly). **If it exits with COPYLEFT FOUND: stop the entire plan and report to the maintainer** — the MIT decision is contingent on this gate. If it exits with "hand review" names, inspect those repos' LICENSE files yourself; if they are permissive-but-custom (e.g. Swift.org's Apache-2.0-with-Runtime-Library-Exception sometimes classifies as OTHER), note the real license, hardcode nothing — fix by reading and, if genuinely permissive, add a fallback mapping in the python (`OVERRIDES = {"identity": "Apache-2.0"}` applied after `spdx` is read, with a comment saying which LICENSE file you read to justify it).

- [ ] **Step 5: Verify outputs**

```bash
python3 -m json.tool App/Resources/acknowledgements.json > /dev/null && echo JSON-OK
grep -c '^### ' THIRD-PARTY-NOTICES.md   # expect ~40+ (38 packages + unique license texts)
scripts/generate-notices.sh && git diff --stat THIRD-PARTY-NOTICES.md App/Resources/acknowledgements.json
```

Expected: `JSON-OK`; second run produces **no diff** (idempotent). Skim `THIRD-PARTY-NOTICES.md` yourself: every package section has a license, the license-text appendix looks sane, swift-nio's NOTICE block is present.

- [ ] **Step 6: Commit**

```bash
git add scripts/generate-notices.sh scripts/model-acknowledgements.json THIRD-PARTY-NOTICES.md App/Resources/acknowledgements.json
git commit -m "scripts: license audit + generated third-party notices

All 38 resolved packages are permissive (Apache-2.0/MIT/BSD family) — MIT
umbrella confirmed. generate-notices.sh regenerates THIRD-PARTY-NOTICES.md
and the app's bundled acknowledgements.json; it hard-fails on copyleft.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

(Adjust the "38" and the license-family claim to what the audit actually found.)

---

### Task 2: In-app Acknowledgements screen

**Files:**
- Create: `App/Sources/Views/AcknowledgementsView.swift`
- Modify: `App/project.yml` (add `Resources` to the Luxicon target's sources)
- Modify: `App/Sources/Views/MyVoiceView.swift` (row in the "Davidson College" section, ~line 180–197)

**Interfaces:**
- Consumes: `App/Resources/acknowledgements.json` from Task 1 — shape `{"packages": [{"name": String, "version": String?, "license": String, "url": String, "copyright": String?}], "models": [same]}`.
- Produces: `AcknowledgementsView` (no-argument SwiftUI view), pushed via `NavigationLink` from MyVoiceView.

- [ ] **Step 1: Add the Resources folder to the app target**

In `App/project.yml`, the Luxicon target's sources currently read:

```yaml
    sources:
      - Sources
      - Shared
      - Assets.xcassets
```

Change to:

```yaml
    sources:
      - Sources
      - Shared
      - Assets.xcassets
      - Resources
```

(xcodegen puts non-compilable files like `.json` into the resources build phase automatically. Do NOT add `Resources` to the LuxiconWidgets target.)

- [ ] **Step 2: Write `App/Sources/Views/AcknowledgementsView.swift`**

```swift
import SwiftUI

/// Open-source packages and model weights Luxicon ships with or downloads,
/// from the bundled acknowledgements.json (regenerated by
/// scripts/generate-notices.sh). Rows open the upstream page in Safari —
/// a user-initiated link-out, same as the giving screen's.
struct AcknowledgementsView: View {
    private struct Entry: Decodable, Identifiable {
        let name: String
        let version: String?
        let license: String
        let url: String
        let copyright: String?
        var id: String { name }
    }

    private struct Acknowledgements: Decodable {
        let packages: [Entry]
        let models: [Entry]
    }

    private let acknowledgements: Acknowledgements? = {
        guard let url = Bundle.main.url(forResource: "acknowledgements",
                                        withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Acknowledgements.self, from: data)
    }()

    var body: some View {
        Form {
            if let ack = acknowledgements {
                Section {
                    ForEach(ack.models) { row($0) }
                } header: {
                    Text("Speech models")
                } footer: {
                    Text("Downloaded from Hugging Face on first use and run entirely on this device. Each model carries its own license.")
                }
                Section {
                    ForEach(ack.packages) { row($0) }
                } header: {
                    Text("Swift packages")
                } footer: {
                    Text("Luxicon itself is MIT-licensed. Full license and notice texts are in THIRD-PARTY-NOTICES.md in the source repository.")
                }
            } else {
                Text("Acknowledgements are missing from this build.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Acknowledgements")
    }

    @ViewBuilder
    private func row(_ entry: Entry) -> some View {
        if let url = URL(string: entry.url) {
            Link(destination: url) { label(for: entry) }
        } else {
            label(for: entry)
        }
    }

    private func label(for entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(entry.name)
                    .foregroundStyle(.primary)
                Spacer()
                Text(entry.license)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let version = entry.version, !version.isEmpty {
                Text(version)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
```

- [ ] **Step 3: Add the row in MyVoiceView**

In `App/Sources/Views/MyVoiceView.swift`, the "Davidson College" section (~line 180) currently ends its section body after the About button:

```swift
            Section {
                Button {
                    showingAboutGiving = true
                } label: {
                    HStack(spacing: 12) {
                        Image(decorative: "AppIconLarge")
                            .resizable()
                            .frame(width: 30, height: 30)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        Text("About Luxicon & Giving")
                            .foregroundStyle(.primary)
                    }
                }
            } header: {
```

Add a `NavigationLink` after the Button's closing brace, inside the same Section:

```swift
                NavigationLink {
                    AcknowledgementsView()
                } label: {
                    Text("Open-Source Acknowledgements")
                }
```

- [ ] **Step 4: Regenerate the project and build for device**

```bash
cd App && xcodegen generate && cd ..
cd App && xcodebuild -project Luxicon.xcodeproj -scheme Luxicon \
  -destination 'generic/platform=iOS' -configuration Release \
  -allowProvisioningUpdates build 2>&1 | tail -5; cd ..
```

Expected: `** BUILD SUCCEEDED **`. If the JSON is missing from the bundle, check that `App/Resources/acknowledgements.json` exists (Task 1) and `xcodegen generate` was re-run after editing project.yml.

- [ ] **Step 5: Verify the resource landed in the app bundle**

```bash
ls ~/Library/Developer/Xcode/DerivedData/Luxicon-*/Build/Products/Release-iphoneos/Luxicon.app/acknowledgements.json
```

Expected: the file exists. (On-device visual check happens at final verification, Task 7.)

- [ ] **Step 6: Commit**

```bash
git add App/project.yml App/Sources/Views/AcknowledgementsView.swift App/Sources/Views/MyVoiceView.swift
git commit -m "App: open-source acknowledgements screen

Bundled acknowledgements.json rendered from My Voice → Davidson College.
Carries the Apache-2.0/CC-BY-4.0 attribution in the App Store binary.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

(Do not commit the regenerated `.xcodeproj` unless the repo's history shows generated project files are committed — check `git status`; if `Luxicon.xcodeproj` shows as modified and IS tracked, include it, matching prior practice.)

---

### Task 3: Bundle notices into the Mac listener installer

**Files:**
- Modify: `scripts/build-installer.sh:23-27` (staging block)
- Modify: `packaging/uninstall.sh:17` (cleanup)

**Interfaces:**
- Consumes: `THIRD-PARTY-NOTICES.md` at repo root (Task 1).
- Produces: pkg payload installs `/usr/local/share/luxicon/THIRD-PARTY-NOTICES.md`.

- [ ] **Step 1: Stage the notices file in build-installer.sh**

In `scripts/build-installer.sh`, the staging block currently reads:

```bash
echo "==> Staging payload (version $VERSION)"
mkdir -p "$STAGE/root/usr/local/bin" "$STAGE/root/Library/LaunchAgents" "$STAGE/scripts"
install .build/release/luxicon-mcp "$STAGE/root/usr/local/bin/luxicon-mcp"
install -m 755 packaging/uninstall.sh "$STAGE/root/usr/local/bin/luxicon-listener-uninstall"
install -m 644 packaging/edu.davidson.luxicon.listener.plist "$STAGE/root/Library/LaunchAgents/"
install -m 755 packaging/postinstall "$STAGE/scripts/postinstall"
```

Add after the last `install` line:

```bash
mkdir -p "$STAGE/root/usr/local/share/luxicon"
install -m 644 THIRD-PARTY-NOTICES.md "$STAGE/root/usr/local/share/luxicon/THIRD-PARTY-NOTICES.md"
```

- [ ] **Step 2: Remove it on uninstall**

In `packaging/uninstall.sh`, after the line

```bash
rm -f "/Library/LaunchAgents/$LABEL.plist" /usr/local/bin/luxicon-mcp
```

add:

```bash
rm -rf /usr/local/share/luxicon
```

- [ ] **Step 3: Verify with an unsigned test build**

```bash
swift build -c release --product luxicon-mcp >/dev/null && scripts/build-installer.sh 2>&1 | tail -3
pkgutil --expand-full dist/LuxiconListener-*.pkg /tmp/luxicon-pkg-check 2>/dev/null || \
  pkgutil --expand dist/LuxiconListener-*.pkg /tmp/luxicon-pkg-check
find /tmp/luxicon-pkg-check -name 'THIRD-PARTY-NOTICES.md'
rm -rf /tmp/luxicon-pkg-check
```

Expected: `find` prints one path containing `usr/local/share/luxicon/THIRD-PARTY-NOTICES.md`. (Unsigned build is fine — we're checking payload layout, not distribution. Do NOT set signing env vars.)

- [ ] **Step 4: Commit**

```bash
git add scripts/build-installer.sh packaging/uninstall.sh
git commit -m "packaging: ship THIRD-PARTY-NOTICES.md in the listener pkg

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: CONTRIBUTING.md

**Files:**
- Create: `CONTRIBUTING.md`

**Interfaces:**
- Consumes: nothing.
- Produces: `CONTRIBUTING.md` at repo root; Task 6's PR template and Task 7's README link to it by that exact path.

- [ ] **Step 1: Write `CONTRIBUTING.md`**

```markdown
# Contributing to Luxicon

Thanks for your interest. Luxicon is built and maintained by a small team
at Davidson College Technology & Innovation — we genuinely welcome issues
and pull requests, and we're honest about capacity: expect a response
within a week or two, not hours. Small, focused contributions land fastest.

## Ways to help

- **Bug reports.** Use the bug-report issue form. Device model, OS version,
  and (for transcription issues) which engine you were using are the three
  things we always need. Never paste transcript content from a real
  1-on-1 into an issue.
- **Docs.** Unclear setup steps, missing troubleshooting — PRs welcome, no
  issue needed.
- **Code.** For anything bigger than a small fix, open an issue first so we
  can agree on the approach before you spend your evening on it.

## Development setup

Luxicon has three surfaces. You can work on the Swift package with just a
Mac; the iOS app needs a physical iPhone.

### Swift package (LuxiconKit, luxicon-cli, luxicon-mcp)

```bash
swift build
swift test                                  # offline, no model downloads
bash scripts/build_mlx_metallib.sh debug    # once, before running the CLI
.build/debug/luxicon-cli meeting.wav --out ./out
```

First run may require the Metal toolchain:
`xcodebuild -downloadComponent MetalToolchain`.

### iOS app

Requires Xcode 26+ to build (iOS 26 SDK symbols, runtime-gated; deployment
target is iOS 18) and a **physical device** — diarization uses MLX/Metal
and does not run in the Simulator.

```bash
brew install xcodegen
cd App && xcodegen generate
open Luxicon.xcodeproj    # set your signing team, build & run on device
```

### Mac sync listener

Install only via `scripts/install-listener.sh` — it builds, codesigns, and
allows the binary through the macOS firewall. A hand-copied binary gets
silently firewall-blocked (the firewall keys its "Allow" to the code
signature). `luxicon-cli push export.json --token <token> --host 127.0.0.1`
exercises the sync path without a phone.

## Testing

- `swift test` covers LuxiconKit and must pass. Tests are offline — never
  add a test that downloads a model or touches the network.
- There is no app test bundle. App changes are verified by building and
  checking on a device; say in your PR what you checked.

## Things that will bite you

- **`App/Luxicon.xcodeproj` is generated.** Never edit it. Edit
  `App/project.yml` and run `cd App && xcodegen generate` after
  adding/removing source files.
- **Persistence back-compat.** `Store.Persisted` and `SessionRecord` must
  keep decoding `store.json` files written by released builds: new fields
  are optionals (or get defaults in `load()`); never rename or repurpose
  existing keys. Secrets go in the Keychain, never in `store.json`.
- **Wire-protocol changes** (`LuxiconSync`, `SyncPusher`, `SyncListener`)
  span the app and the installed Mac binary. After changing them, reinstall
  both sides and test a real push, or pushes fail in confusing ways.
- **The privacy posture is load-bearing.** "Everything on-device; the only
  network features are opt-in Mac sync and https-only vocabulary/people
  sync" is App Store copy. PRs that add any other network call will be
  declined regardless of how useful the feature is.

## Pull requests

- Build and test before submitting (`swift build && swift test`; plus a
  device build if you touched `App/`).
- Keep PRs focused — one change per PR.
- If you add, remove, or update a dependency, run
  `scripts/generate-notices.sh` and commit the regenerated
  `THIRD-PARTY-NOTICES.md` and `App/Resources/acknowledgements.json`.
- By contributing you agree your contribution is licensed under the
  project's MIT license (the standard inbound = outbound arrangement).

## Conduct and security

We follow the [Contributor Covenant](CODE_OF_CONDUCT.md). Security issues:
please use the private process in [SECURITY.md](SECURITY.md), not a public
issue.
```

- [ ] **Step 2: Verify internal links resolve**

```bash
ls CODE_OF_CONDUCT.md SECURITY.md scripts/install-listener.sh scripts/generate-notices.sh 2>&1
```

Expected: `CODE_OF_CONDUCT.md` missing (created in Task 5 — fine if executing in order; re-check at Task 7), everything else exists. If executing tasks out of order, note the dependency.

- [ ] **Step 3: Commit**

```bash
git add CONTRIBUTING.md
git commit -m "docs: contributing guide

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: CODE_OF_CONDUCT.md

**Files:**
- Create: `CODE_OF_CONDUCT.md`

**Interfaces:**
- Consumes: canonical Contributor Covenant 2.1 text (network fetch).
- Produces: `CODE_OF_CONDUCT.md` at repo root with contact `jdmills@davidson.edu`; linked by Task 4's CONTRIBUTING and Task 7's README.

- [ ] **Step 1: Fetch the canonical text and fill in the contact**

```bash
curl -fsSL https://www.contributor-covenant.org/version/2/1/code_of_conduct/code_of_conduct.md \
  -o CODE_OF_CONDUCT.md
python3 - <<'PY'
import pathlib
p = pathlib.Path("CODE_OF_CONDUCT.md")
t = p.read_text()
assert "[INSERT CONTACT METHOD]" in t, "canonical text changed — fill contact by hand"
p.write_text(t.replace("[INSERT CONTACT METHOD]", "jdmills@davidson.edu"))
PY
```

If the URL 404s (site reorganized), fetch from the project's GitHub instead: `https://raw.githubusercontent.com/EthicalSource/contributor_covenant/release/content/version/2/1/code_of_conduct.md` — same replace step. Strip any YAML/TOML frontmatter block if the raw file has one.

- [ ] **Step 2: Verify no placeholder remains and the contact is set**

```bash
grep -c "INSERT CONTACT" CODE_OF_CONDUCT.md; grep -c "jdmills@davidson.edu" CODE_OF_CONDUCT.md
head -3 CODE_OF_CONDUCT.md
```

Expected: `0`, then `1` (or more), and the head shows `# Contributor Covenant Code of Conduct` (no frontmatter).

- [ ] **Step 3: Commit**

```bash
git add CODE_OF_CONDUCT.md
git commit -m "docs: adopt Contributor Covenant 2.1

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: GitHub issue forms + PR template

**Files:**
- Create: `.github/ISSUE_TEMPLATE/bug_report.yml`
- Create: `.github/ISSUE_TEMPLATE/feature_request.yml`
- Create: `.github/ISSUE_TEMPLATE/config.yml`
- Create: `.github/PULL_REQUEST_TEMPLATE.md`

**Interfaces:**
- Consumes: `CONTRIBUTING.md` path (Task 4), SECURITY.md (exists).
- Produces: templates GitHub picks up automatically from `.github/`.

- [ ] **Step 1: Write `.github/ISSUE_TEMPLATE/bug_report.yml`**

```yaml
name: Bug report
description: Something broke or behaved wrong
labels: [bug]
body:
  - type: markdown
    attributes:
      value: >-
        Thanks for the report. One privacy note: never paste transcript
        content from a real 1-on-1 — describe the shape of the problem
        instead, or reproduce it with a test recording.
  - type: dropdown
    id: surface
    attributes:
      label: Surface
      options:
        - iOS app
        - luxicon-cli
        - luxicon-mcp (MCP server)
        - Mac sync listener
        - Docs / other
    validations:
      required: true
  - type: input
    id: device
    attributes:
      label: Device and OS
      description: e.g. "iPhone 15 Pro, iOS 26.1" or "MacBook Air M2, macOS 15.5"
    validations:
      required: true
  - type: dropdown
    id: engine
    attributes:
      label: Transcription engine (for transcription issues)
      options:
        - Automatic
        - Apple
        - Luxicon (Parakeet)
        - Not applicable / don't know
  - type: textarea
    id: what
    attributes:
      label: What happened
      description: Steps to reproduce, what you expected, what you got instead.
    validations:
      required: true
```

- [ ] **Step 2: Write `.github/ISSUE_TEMPLATE/feature_request.yml`**

```yaml
name: Feature request
description: An idea for making Luxicon better
labels: [enhancement]
body:
  - type: textarea
    id: problem
    attributes:
      label: The problem
      description: What are you trying to do that Luxicon doesn't support?
    validations:
      required: true
  - type: textarea
    id: proposal
    attributes:
      label: Proposed solution
      description: How you imagine it working. Sketches welcome.
  - type: markdown
    attributes:
      value: >-
        Heads up: Luxicon's privacy posture is a hard constraint — everything
        on-device, no network calls beyond opt-in Mac sync (LAN-only) and
        https vocabulary/people sync. Features that need other network
        access will be declined.
```

- [ ] **Step 3: Write `.github/ISSUE_TEMPLATE/config.yml`**

```yaml
blank_issues_enabled: true
contact_links:
  - name: Report a security vulnerability
    url: https://github.com/DavidsonCollege/luxicon/security/advisories/new
    about: Please report exploitable vulnerabilities privately — see SECURITY.md.
```

- [ ] **Step 4: Write `.github/PULL_REQUEST_TEMPLATE.md`**

```markdown
## What & why

<!-- One or two sentences. Link the issue if there is one. -->

## Checklist

- [ ] `swift build` and `swift test` pass
- [ ] App changes: ran `cd App && xcodegen generate` after adding/removing
      files, and built/checked on a physical device
- [ ] No new network calls outside the documented opt-in paths
      (see "Things that will bite you" in CONTRIBUTING.md)
- [ ] Wire-protocol changes (`LuxiconSync`/`SyncPusher`/`SyncListener`):
      reinstalled both sides and tested a real push
- [ ] Dependency changes: ran `scripts/generate-notices.sh` and committed
      the regenerated outputs
```

- [ ] **Step 5: Validate YAML parses**

```bash
ruby -ryaml -e 'Dir[".github/ISSUE_TEMPLATE/*.yml"].each { |f| YAML.load_file(f); puts "OK #{f}" }'
```

Expected: `OK` for all three files. (Ruby ships with macOS; if it's absent, `python3 -c "import yaml"` + `yaml.safe_load` works when PyYAML is installed.)

- [ ] **Step 6: Commit**

```bash
git add .github
git commit -m "docs: issue forms and PR template

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: README, repo metadata, changelog, final verification

**Files:**
- Modify: `README.md` (License section, ~line 172-178; add Contributing section above it)
- Modify: `CHANGELOG.md` (new entry at top, matching existing entry style — read the file first)

**Interfaces:**
- Consumes: every file created in Tasks 1-6.
- Produces: the finished repo surface.

- [ ] **Step 1: README — add Contributing, expand License**

The README currently ends with:

```markdown
## License

MIT. Depends on [speech-swift](https://github.com/soniqo/speech-swift)
(Apache 2.0) and the
[MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) (MIT);
model weights carry their own licenses (Pyannote segmentation: MIT;
WeSpeaker: Apache 2.0; Parakeet: CC-BY-4.0).
```

Replace with (adjust the license-family phrase and model list if Task 1's audit found anything different):

```markdown
## Contributing

Bug reports and pull requests are welcome — see
[CONTRIBUTING.md](CONTRIBUTING.md) for dev setup, testing expectations,
and the handful of things that will bite you. We follow the
[Contributor Covenant](CODE_OF_CONDUCT.md); report security issues
privately per [SECURITY.md](SECURITY.md).

## License

MIT — see [LICENSE](LICENSE). Every dependency is permissive
(Apache-2.0 / MIT / BSD family); the full inventory with license and
notice texts is in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md),
mirrored in the app under My Voice → Open-Source Acknowledgements.
Model weights carry their own licenses (Pyannote segmentation: MIT;
WeSpeaker: Apache 2.0; Parakeet: CC-BY-4.0).
```

- [ ] **Step 2: CHANGELOG entry**

Read `CHANGELOG.md` first and match its heading/voice exactly. Add an entry at the top describing: open-source acknowledgements screen in the app, THIRD-PARTY-NOTICES + generator script, contributing guide / code of conduct / issue templates, notices shipped in the listener installer.

- [ ] **Step 3: Set repo topics**

```bash
gh repo edit DavidsonCollege/luxicon \
  --add-topic ios --add-topic swift --add-topic swiftui \
  --add-topic speech-recognition --add-topic speaker-diarization \
  --add-topic transcription --add-topic on-device --add-topic privacy \
  --add-topic mcp
gh repo view DavidsonCollege/luxicon --json repositoryTopics --jq '.repositoryTopics[].name'
```

Expected: the nine topics echoed back.

- [ ] **Step 4: Full verification sweep**

```bash
swift build 2>&1 | tail -1                 # expect: Build complete!
swift test 2>&1 | tail -3                  # expect: all suites pass
scripts/generate-notices.sh && git status --porcelain THIRD-PARTY-NOTICES.md App/Resources/acknowledgements.json
                                           # expect: no output (idempotent)
ls CONTRIBUTING.md CODE_OF_CONDUCT.md SECURITY.md THIRD-PARTY-NOTICES.md \
   .github/PULL_REQUEST_TEMPLATE.md .github/ISSUE_TEMPLATE/bug_report.yml \
   .github/ISSUE_TEMPLATE/feature_request.yml .github/ISSUE_TEMPLATE/config.yml
grep -n "CODE_OF_CONDUCT" CONTRIBUTING.md README.md   # links resolve now that Task 5 ran
```

Also install the Release build on the maintainer's iPhone (see repo memory: `xcrun devicectl device install app --device <id> ...`) OR flag for the maintainer to visually verify the Acknowledgements screen — every entry renders, links open Safari.

- [ ] **Step 5: Commit**

```bash
git add README.md CHANGELOG.md
git commit -m "docs: contributing + license sections in README, changelog

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Post-plan

All work is on `main` per repo convention unless the maintainer prefers a branch — repo history shows feature branches + PRs (e.g. `feat/apple-speech-engine`), so **create a branch `chore/open-source-hygiene` before Task 1 and open a PR at the end** using the commit trail above.
