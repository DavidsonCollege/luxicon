#!/bin/bash
# Build, Developer-ID-sign, package (DMG), notarize, and staple Luxicon for Mac.
#
# Output: dist/Luxicon-<marketing>-<build>.dmg
#
# Credentials (locations only — see docs/releasing.md, Flow 3):
#   - "Developer ID Application" identity in the login keychain
#   - notarytool keychain profile `luxicon`
#
# LUXICON_SKIP_NOTARIZE=1 builds a signed, NOT notarized DMG for local testing.
# Such a DMG must never be published.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
SKIP_NOTARIZE="${LUXICON_SKIP_NOTARIZE:-0}"
XCFLAGS=(-skipPackagePluginValidation -skipMacroValidation)

if [ "$SKIP_NOTARIZE" != "1" ]; then
    echo "==> Checking notarytool keychain profile 'luxicon'"
    if ! xcrun notarytool history --keychain-profile luxicon >/dev/null 2>&1; then
        echo "error: notarytool keychain profile 'luxicon' is missing or invalid." >&2
        echo "       Create it in Terminal.app (needs an app-specific password):" >&2
        echo "         xcrun notarytool store-credentials luxicon --apple-id <account> --team-id 4Z539UE4TT" >&2
        echo "       See docs/releasing.md (Flow 3). For a local, non-publishable build," >&2
        echo "       re-run with LUXICON_SKIP_NOTARIZE=1." >&2
        exit 1
    fi
fi

WORK=$(mktemp -d)
MOUNT=""
cleanup() {
    if [ -n "$MOUNT" ]; then hdiutil detach "$MOUNT" -quiet 2>/dev/null || true; rmdir "$MOUNT" 2>/dev/null || true; fi
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "==> xcodegen"
(cd App && xcodegen generate)

echo "==> Reading version"
SETTINGS=$(cd App && xcodebuild -project Luxicon.xcodeproj -scheme LuxiconMac \
    -configuration Release "${XCFLAGS[@]}" -showBuildSettings 2>/dev/null)
MARKETING=$(awk -F' = ' '/^ *MARKETING_VERSION = /{print $2; exit}' <<<"$SETTINGS")
BUILD=$(awk -F' = ' '/^ *CURRENT_PROJECT_VERSION = /{print $2; exit}' <<<"$SETTINGS")
[ -n "$MARKETING" ] && [ -n "$BUILD" ] || { echo "error: could not read version" >&2; exit 1; }
echo "    version $MARKETING ($BUILD)"

echo "==> Archive (Apple silicon only: MLX/speech deps do not build for x86_64)"
(cd App && xcodebuild -project Luxicon.xcodeproj -scheme LuxiconMac \
    -configuration Release -destination 'platform=macOS,arch=arm64' \
    "${XCFLAGS[@]}" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    -archivePath "$WORK/LuxiconMac.xcarchive" archive)

echo "==> Export (Developer ID)"
# If this fails with "Failed to Use Accounts", stop: see docs/releasing.md.
xcodebuild -exportArchive -archivePath "$WORK/LuxiconMac.xcarchive" \
    -exportOptionsPlist "$ROOT/packaging/mac-export-options.plist" \
    -exportPath "$WORK/export" "${XCFLAGS[@]}"
APP="$WORK/export/Luxicon.app"
[ -d "$APP" ] || { echo "error: export produced no Luxicon.app" >&2; exit 1; }

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
ENT=$(codesign -d --entitlements - "$APP" 2>&1)
if ! grep -q "audio-input" <<<"$ENT"; then
    echo "error: app is missing the audio-input entitlement" >&2
    exit 1
fi
echo "    entitlements include audio-input"

echo "==> Staging DMG"
STAGE="$WORK/stage"
mkdir -p "$STAGE" dist
ditto "$APP" "$STAGE/Luxicon.app"
ln -s /Applications "$STAGE/Applications"
DMG="dist/Luxicon-$MARKETING-$BUILD.dmg"
rm -f "$DMG"
hdiutil create -volname Luxicon -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo "==> Signing DMG"
codesign --sign "Developer ID Application" --timestamp "$DMG"
codesign --verify --verbose=2 "$DMG"

if [ "$SKIP_NOTARIZE" = "1" ]; then
    echo "==> LUXICON_SKIP_NOTARIZE=1: skipping notarize/staple"
    MOUNT=$(mktemp -d)
    hdiutil attach "$DMG" -mountpoint "$MOUNT" -nobrowse -readonly -quiet
    spctl -a -vv "$MOUNT/Luxicon.app" || true
    echo
    echo "WARNING: $DMG is signed but NOT notarized. Do not publish it."
    echo "Built $DMG (not notarized)"
    exit 0
fi

echo "==> Notarizing (keychain profile: luxicon)"
xcrun notarytool submit "$DMG" --keychain-profile luxicon --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "==> Gatekeeper checks"
spctl -a -vv -t install "$DMG"
MOUNT=$(mktemp -d)
hdiutil attach "$DMG" -mountpoint "$MOUNT" -nobrowse -readonly -quiet
spctl -a -vv "$MOUNT/Luxicon.app"

echo "Built $DMG"
