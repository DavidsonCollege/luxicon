#!/bin/bash
# Build, Developer-ID-sign, notarize and staple the app, package it (DMG),
# then notarize and staple the DMG, for Luxicon for Mac.
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

if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    echo "warning: the git tree has uncommitted changes; a release should be built from a" >&2
    echo "         committed state (continuing)." >&2
    git status --short >&2
fi

WORK=$(mktemp -d)
MOUNT=""
cleanup() {
    if [ -n "$MOUNT" ]; then hdiutil detach "$MOUNT" -quiet 2>/dev/null || true; rmdir "$MOUNT" 2>/dev/null || true; fi
    rm -rf "$WORK"
}
trap cleanup EXIT

# notarize <file> <label>: submit to the notary service (keychain profile
# `luxicon`), wait, and fail unless the status is Accepted, printing the
# notary log when there is one.
notarize() {
    local file=$1 label=$2
    local json="$WORK/notarize-$label.json"
    echo "==> Notarizing $label (keychain profile: luxicon)"
    xcrun notarytool submit "$file" --keychain-profile luxicon --wait \
        --output-format json > "$json" || true
    cat "$json"
    local status id
    status=$(plutil -extract status raw -o - "$json" 2>/dev/null || echo unknown)
    if [ "$status" != "Accepted" ]; then
        id=$(plutil -extract id raw -o - "$json" 2>/dev/null || echo "")
        echo "error: $label notarization status is '$status' (submission id: ${id:-unknown})" >&2
        if [ -n "$id" ]; then
            xcrun notarytool log "$id" --keychain-profile luxicon >&2 || true
        fi
        exit 1
    fi
}

echo "==> xcodegen"
(cd App && xcodegen generate)

echo "==> Reading version"
if ! SETTINGS=$(cd App && xcodebuild -project Luxicon.xcodeproj -scheme LuxiconMac \
    -configuration Release "${XCFLAGS[@]}" -showBuildSettings 2>"$WORK/settings.err"); then
    echo "error: xcodebuild -showBuildSettings failed:" >&2
    cat "$WORK/settings.err" >&2
    exit 1
fi
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
SIGINFO=$(codesign -dv "$APP" 2>&1)
if ! grep -Eq 'flags=0x[0-9a-f]+\(.*runtime.*\)' <<<"$SIGINFO"; then
    echo "error: app is not signed with the hardened runtime" >&2
    exit 1
fi
echo "    hardened runtime enabled"
codesign -d --entitlements - --xml "$APP" > "$WORK/entitlements.plist" 2>/dev/null
KEYS=$(plutil -convert json -o - "$WORK/entitlements.plist")
if [ "$KEYS" != '{"com.apple.security.device.audio-input":true}' ]; then
    echo "error: unexpected entitlements (want only audio-input=true): $KEYS" >&2
    exit 1
fi
echo "    entitlements: audio-input only (true)"

echo "==> Checking for the MLX Metal library"
# Diarization needs MLX's compiled shaders; without them it fails at runtime.
METALLIBS=$(find "$APP/Contents/Resources" -name '*.metallib' -type f)
if [ -z "$METALLIBS" ]; then
    echo "error: no *.metallib under $APP/Contents/Resources (MLX shaders missing)" >&2
    exit 1
fi
sed "s|^$APP/|    |" <<<"$METALLIBS"

if [ "$SKIP_NOTARIZE" != "1" ]; then
    # Notarize and staple the app itself, so a copy dragged out of the DMG
    # carries its own ticket and validates offline.
    ditto -c -k --keepParent "$APP" "$WORK/Luxicon.zip"
    notarize "$WORK/Luxicon.zip" app
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
fi

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

notarize "$DMG" dmg
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "==> Gatekeeper checks"
spctl -a -vv -t install "$DMG"
MOUNT=$(mktemp -d)
hdiutil attach "$DMG" -mountpoint "$MOUNT" -nobrowse -readonly -quiet
spctl -a -vv "$MOUNT/Luxicon.app"

echo "Built $DMG"
