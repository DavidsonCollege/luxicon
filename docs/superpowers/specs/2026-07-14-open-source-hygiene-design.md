# Open-source hygiene: license compliance, contribution docs, repo polish

**Date:** 2026-07-14
**Status:** Approved

## Goal

Make the Luxicon repo a first-class open source project: verified license
posture, dependency attribution that satisfies every upstream license in
both the repo and the shipped binaries, contribution guidelines that match
the team's real capacity, and standard community files.

## Decisions already made

- **Contribution posture:** welcoming but honest — invite issues and PRs,
  document setup thoroughly, be explicit that a small college team reviews
  on a best-effort cadence.
- **License:** keep MIT (copyright Davidson College), contingent on the
  dependency audit finding no copyleft. Rationale: matches the project's
  free-service intent, compatible with the all-permissive dependency tree,
  clean for App Store distribution, zero contributor paperwork.
- **Attribution depth:** full — a repo notices file *and* an in-app
  Acknowledgements screen, so the App Store binary itself carries the
  Apache-2.0 / CC-BY-4.0 notices.
- **Tooling approach:** script-assisted, checked-in output (approach A).
  No build-time license plugins.

## Components

### 1. Dependency license audit

Audit every package in `Package.resolved` (38 pins) plus the three model
weights (Parakeet TDT: CC-BY-4.0; Pyannote segmentation: MIT; WeSpeaker:
Apache-2.0). For each: license identifier, copyright line, NOTICE file if
present. **Gate:** if anything copyleft (GPL/LGPL/MPL/AGPL) or
non-commercial turns up, stop and report before any other license work.
Expected outcome: all Apache-2.0 / MIT / BSD-style, MIT umbrella confirmed.

### 2. `scripts/generate-notices.sh` + generated outputs

A script that reads `Package.resolved`, fetches each dependency's LICENSE
(and NOTICE where present) from its repo at the pinned version, and emits:

- **`THIRD-PARTY-NOTICES.md`** (repo root) — one section per dependency:
  name, version, license type, copyright line, upstream link; verbatim
  NOTICE contents for Apache deps that ship one; a hand-maintained
  model-weights section (script preserves it between markers).
- **`App/Resources/acknowledgements.json`** (path adjusted to match app
  conventions) — machine-readable list `{name, version, license, url,
  copyright}` plus model credits, bundled into the app.

Both outputs are checked in and regenerated only when dependencies change.
Script requires network + `gh`; it is a maintainer tool, never part of the
build. CONTRIBUTING documents when to re-run it.

### 3. In-app Acknowledgements screen

New screen reachable from the app's settings area: a plain SwiftUI list of
dependencies (name, license, tappable upstream link via the standard
link-out) and a model-weights section with the CC-BY-4.0 Parakeet
attribution. Driven by the bundled JSON; no network. Follows existing app
patterns (Store extensions, generated project — update `project.yml` +
`xcodegen generate` for the new resource). This satisfies binary-
distribution attribution for the App Store build.

The Mac listener installer pkg bundles `THIRD-PARTY-NOTICES.md` into its
resources so the notarized installer distribution is covered too.

### 4. `CONTRIBUTING.md`

Sections: what the project is / who maintains it; ways to help (bug
reports with device+iOS+engine info, docs, code); dev setup for all three
surfaces (Swift package + metallib script; iOS app via xcodegen + physical
device requirement; listener via install script only); testing rules
(LuxiconKit-only, offline, `swift test`); the landmines (never edit the
generated .xcodeproj; `store.json` back-compat rules; wire-protocol
changes require reinstalling both sides; no new network calls outside the
documented opt-in paths — privacy posture is load-bearing App Store copy);
PR expectations (small focused PRs, build+test before submitting, honest
"review may take a week or two"); when to re-run the notices script;
inbound=outbound MIT note.

### 5. `CODE_OF_CONDUCT.md`

Contributor Covenant 2.1, contact jdmills@davidson.edu.

### 6. `.github/` templates

- `ISSUE_TEMPLATE/bug_report.yml` — form asking device model, iOS/macOS
  version, transcription engine, surface (app/CLI/MCP/listener), repro.
- `ISSUE_TEMPLATE/feature_request.yml` — problem, proposal, privacy-posture
  fit.
- `ISSUE_TEMPLATE/config.yml` — blank issues on; link security reports to
  SECURITY.md private reporting.
- `PULL_REQUEST_TEMPLATE.md` — checklist mirroring CONTRIBUTING (built,
  tested, xcodegen run if app files changed, no new network calls).

### 7. README + repo metadata

- README: add short Contributing section linking CONTRIBUTING.md and the
  code of conduct; expand License section to link THIRD-PARTY-NOTICES.md.
- GitHub: set repo topics (ios, swift, speech-recognition, diarization,
  speaker-diarization, on-device, mcp, privacy, transcription).

## Out of scope

CLA/DCO machinery, roadmap documents, release-cadence commitments,
build-time license tooling, relicensing.

## Testing / verification

- `swift build` and `swift test` still pass (script and docs are inert;
  app change is UI-only).
- App builds Release for device after `xcodegen generate`; Acknowledgements
  screen renders every entry from the bundled JSON.
- Notices script re-run is idempotent (no diff when deps unchanged).
- Audit results cross-checked by hand for the three model weights and any
  dependency whose license the script can't fetch.

## Error handling

- Script: a dependency whose LICENSE can't be fetched is listed in the
  output as `UNRESOLVED` and the script exits nonzero — never silently
  omitted.
- Audit gate: copyleft discovery halts the license work and gets reported
  to the maintainer before proceeding.
