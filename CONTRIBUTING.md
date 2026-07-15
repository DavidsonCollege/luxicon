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
