#!/bin/bash
# Build the double-clickable installer for the Mac sync listener.
#
# Unsigned by default (right-click → Open to test locally). For a
# distributable build set:
#   LUXICON_SIGN_IDENTITY       "Developer ID Application: …"  (signs the binary)
#   LUXICON_INSTALLER_IDENTITY  "Developer ID Installer: …"    (signs the pkg)
# and store notarization credentials once:
#   xcrun notarytool store-credentials luxicon --apple-id … --team-id … --password …
# With both identities set, the pkg is signed, notarized (--wait), and stapled.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${LUXICON_PKG_VERSION:-$(git describe --tags --always 2>/dev/null || echo 0.0.0)}"
ID=edu.davidson.luxicon.listener.pkg
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

echo "==> Building luxicon-mcp (release, $(uname -m))"
swift build -c release --product luxicon-mcp

echo "==> Staging payload (version $VERSION)"
mkdir -p "$STAGE/root/usr/local/bin" "$STAGE/root/Library/LaunchAgents" "$STAGE/scripts"
install .build/release/luxicon-mcp "$STAGE/root/usr/local/bin/luxicon-mcp"
install -m 755 packaging/uninstall.sh "$STAGE/root/usr/local/bin/luxicon-listener-uninstall"
install -m 644 packaging/edu.davidson.luxicon.listener.plist "$STAGE/root/Library/LaunchAgents/"
install -m 755 packaging/postinstall "$STAGE/scripts/postinstall"

if [ -n "${LUXICON_SIGN_IDENTITY:-}" ]; then
    echo "==> Signing binary as: $LUXICON_SIGN_IDENTITY"
    # Hardened runtime + timestamp: both required for notarization.
    codesign --force --options runtime --timestamp \
        --sign "$LUXICON_SIGN_IDENTITY" "$STAGE/root/usr/local/bin/luxicon-mcp"
else
    echo "==> WARNING: LUXICON_SIGN_IDENTITY unset — binary unsigned (test builds only)."
fi

echo "==> pkgbuild"
pkgbuild --root "$STAGE/root" --scripts "$STAGE/scripts" \
    --identifier "$ID" --version "$VERSION" \
    --ownership recommended "$STAGE/listener.pkg" >/dev/null

mkdir -p dist
OUT="dist/LuxiconListener-$VERSION.pkg"
sed "s/@VERSION@/$VERSION/" packaging/distribution.xml > "$STAGE/distribution.xml"

echo "==> productbuild"
if [ -n "${LUXICON_INSTALLER_IDENTITY:-}" ]; then
    productbuild --distribution "$STAGE/distribution.xml" --package-path "$STAGE" \
        --resources packaging/resources \
        --sign "$LUXICON_INSTALLER_IDENTITY" "$OUT" >/dev/null
    echo "==> Notarizing (keychain profile: luxicon)"
    xcrun notarytool submit "$OUT" --keychain-profile luxicon --wait
    xcrun stapler staple "$OUT"
    xcrun stapler validate "$OUT"
    echo "==> Gatekeeper check"
    spctl -a -vv -t install "$OUT" || true
else
    productbuild --distribution "$STAGE/distribution.xml" --package-path "$STAGE" \
        --resources packaging/resources "$OUT" >/dev/null
    echo "==> WARNING: unsigned installer — Gatekeeper blocks downloaded copies."
    echo "    Set LUXICON_INSTALLER_IDENTITY (a 'Developer ID Installer' cert)"
    echo "    to sign + notarize for distribution."
fi

echo "Built $OUT"
