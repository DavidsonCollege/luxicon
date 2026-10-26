#!/bin/bash
# Build, Developer-ID-sign, notarize and staple the app, package it (DMG),
# then notarize and staple the DMG, for Luxicon for Mac.
#
# Output: dist/Luxicon-<marketing>-<build>.dmg
#
# Credentials (locations only — see docs/releasing.md, Flow 3):
#   - "Developer ID Application" identity in the login keychain
#   - notarytool: AC_APPLE_ID + AC_TEAM_ID + AC_APP_PASSWORD from the environment
#     when all three are set (CI), otherwise keychain profile `luxicon` (local)
#
# LUXICON_SKIP_NOTARIZE=1 builds a signed, NOT notarized DMG for local testing.
# Such a DMG must never be published.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
SKIP_NOTARIZE="${LUXICON_SKIP_NOTARIZE:-0}"
XCFLAGS=(-skipPackagePluginValidation -skipMacroValidation)

# notarytool credentials: env (CI) when all three are set, else the keychain profile.
# Values are only ever passed as arguments, never printed.
if [ -n "${AC_APPLE_ID:-}" ] && [ -n "${AC_TEAM_ID:-}" ] && [ -n "${AC_APP_PASSWORD:-}" ]; then
    NOTARY_AUTH=(--apple-id "$AC_APPLE_ID" --team-id "$AC_TEAM_ID" --password "$AC_APP_PASSWORD")
    NOTARY_AUTH_LABEL="environment credentials"
else
    NOTARY_AUTH=(--keychain-profile luxicon)
    NOTARY_AUTH_LABEL="keychain profile: luxicon"
fi

if [ "$SKIP_NOTARIZE" != "1" ] && [ "${NOTARY_AUTH[0]}" = "--keychain-profile" ]; then
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

# notarize <file> <label>: submit to the notary service (NOTARY_AUTH), wait, and fail unless the status is Accepted, printing the
# notary log when there is one.
notarize() {
    local file=$1 label=$2
    local json="$WORK/notarize-$label.json"
    echo "==> Notarizing $label ($NOTARY_AUTH_LABEL)"
    xcrun notarytool submit "$file" "${NOTARY_AUTH[@]}" --wait \
        --output-format json > "$json" || true
    cat "$json"
    local status id
    status=$(plutil -extract status raw -o - "$json" 2>/dev/null || echo unknown)
    if [ "$status" != "Accepted" ]; then
        id=$(plutil -extract id raw -o - "$json" 2>/dev/null || echo "")
        echo "error: $label notarization status is '$status' (submission id: ${id:-unknown})" >&2
        if [ -n "$id" ]; then
            xcrun notarytool log "$id" "${NOTARY_AUTH[@]}" >&2 || true
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
check_entitlements() {
    codesign -d --entitlements - --xml "$APP" > "$WORK/entitlements.plist" 2>/dev/null
    local keys
    keys=$(plutil -convert json -o - "$WORK/entitlements.plist")
    if [ "$keys" != '{"com.apple.security.device.audio-input":true}' ]; then
        echo "error: unexpected entitlements (want only audio-input=true): $keys" >&2
        exit 1
    fi
    echo "    entitlements: audio-input only (true)"
}
check_entitlements

echo "==> Checking Sparkle's helpers"
# Sparkle's nested helpers must carry the hardened runtime and our Developer ID
# authority, or notarization rejects the app.
FW="$APP/Contents/Frameworks/Sparkle.framework"
sparkle_helpers() {
    local x
    [ -d "$FW" ] || return 0
    echo "$FW"
    [ -e "$FW/Versions/B/Autoupdate" ] && echo "$FW/Versions/B/Autoupdate"
    [ -e "$FW/Versions/B/Updater.app" ] && echo "$FW/Versions/B/Updater.app"
    for x in "$FW"/Versions/B/XPCServices/*.xpc; do [ -e "$x" ] && echo "$x"; done
    return 0
}
# check_sparkle: prints one line per helper; returns 1 if any is non-conforming.
check_sparkle() {
    local h info bad=0
    while IFS= read -r h; do
        [ -n "$h" ] || continue
        info=$(codesign -dvv "$h" 2>&1 || true)
        if grep -Eq 'flags=0x[0-9a-f]+\(.*runtime.*\)' <<<"$info" \
            && grep -q '^Authority=Developer ID Application' <<<"$info" \
            && grep -q '^TeamIdentifier=4Z539UE4TT$' <<<"$info"; then
            echo "    ok: ${h#"$APP/Contents/"}"
        else
            echo "    NOT OK (need runtime + Developer ID Application, team 4Z539UE4TT): ${h#"$APP/Contents/"}" >&2
            bad=1
        fi
    done < <(sparkle_helpers)
    return $bad
}
if [ ! -d "$FW" ]; then
    echo "error: $FW is missing (Sparkle must be embedded in the Mac app)" >&2
    exit 1
fi
if ! check_sparkle; then
    echo "==> Export left Sparkle helpers unsigned or ad-hoc; re-signing inside-out"
    sign() { codesign --force --options runtime --timestamp -s "Developer ID Application" "$@"; }
    for x in "$FW"/Versions/B/XPCServices/*.xpc; do [ -e "$x" ] && sign "$x"; done
    [ -e "$FW/Versions/B/Autoupdate" ] && sign "$FW/Versions/B/Autoupdate"
    [ -e "$FW/Versions/B/Updater.app" ] && sign "$FW/Versions/B/Updater.app"
    sign "$FW"
    # Re-seal the app so its signature covers the re-signed helpers; a bare
    # --force would drop the entitlements, so pass them again.
    sign --entitlements "$ROOT/App/LuxiconMac.entitlements" "$APP"
    codesign --verify --deep --strict --verbose=2 "$APP"
    check_sparkle || { echo "error: Sparkle helpers still non-conforming after re-signing" >&2; exit 1; }
    check_entitlements
fi

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
