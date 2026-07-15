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
