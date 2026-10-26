#!/usr/bin/env bash
# Merge a new Luxicon for Mac release into the Sparkle appcast, keeping prior items.
# Adapted from Oncillascope's scripts/make-appcast.sh.
#
# Required env:
#   DMG_PATH             notarized, stapled dist/Luxicon-<marketing>-<build>.dmg
#   RELEASE_NOTES_MD     Markdown file with this release's notes
#   SPARKLE_BIN          directory holding Sparkle's generate_appcast
#   DOWNLOAD_URL_PREFIX  e.g. https://github.com/DavidsonCollege/luxicon/releases/download/mac-v1.0-19/
#   PAGES_DIR            checked-out gh-pages tree; appcast.xml is merged in place
#   ED_KEY_FILE          private EdDSA key file (CI). If unset or empty, the key is
#                        read from the keychain under Luxicon's own account,
#                        edu.davidson.luxicon.mac (never the default account,
#                        which may hold another app's key).
#
# Optional env (local only; CI never sets it):
#   ROTATION_SIGN=1      key rotation release only (docs/releasing.md, "Rotating
#                        the key"): the app carries the NEW SUPublicEDKey, so
#                        generate_appcast leaves its item unsigned. Sign the DMG
#                        with the current (old) key via sign_update instead.
#
# Writes $PAGES_DIR/appcast.xml and $PAGES_DIR/release-notes/Luxicon-<m>-<b>.html,
# and nothing in $PAGES_DIR unless every guard passes.
set -euo pipefail

: "${DMG_PATH:?}"; : "${RELEASE_NOTES_MD:?}"; : "${SPARKLE_BIN:?}"
: "${DOWNLOAD_URL_PREFIX:?}"; : "${PAGES_DIR:?}"

KEYCHAIN_ACCOUNT="edu.davidson.luxicon.mac"
# Enclosures of earlier releases may point at any earlier mac-v* release.
OLDER_URL_PREFIX="https://github.com/DavidsonCollege/luxicon/releases/download/mac-v"

[ -f "$DMG_PATH" ] || { echo "error: DMG_PATH '$DMG_PATH' is not a file" >&2; exit 1; }
[ -f "$RELEASE_NOTES_MD" ] || { echo "error: RELEASE_NOTES_MD '$RELEASE_NOTES_MD' is not a file" >&2; exit 1; }
[ -x "$SPARKLE_BIN/generate_appcast" ] || { echo "error: no generate_appcast in '$SPARKLE_BIN'" >&2; exit 1; }
ROTATION_SIGN="${ROTATION_SIGN:-}"
case "$ROTATION_SIGN" in
  ""|0) ROTATION_SIGN="" ;;
  1) [ -x "$SPARKLE_BIN/sign_update" ] || { echo "error: ROTATION_SIGN needs sign_update in '$SPARKLE_BIN'" >&2; exit 1; } ;;
  *) echo "error: ROTATION_SIGN must be 1 or unset" >&2; exit 1 ;;
esac
[ -d "$PAGES_DIR" ] || { echo "error: PAGES_DIR '$PAGES_DIR' is not a directory" >&2; exit 1; }

dmg_name="$(basename "$DMG_PATH")"
if [[ ! "$dmg_name" =~ ^Luxicon-[0-9]+(\.[0-9]+)*-[0-9]+\.dmg$ ]]; then
  echo "error: '$dmg_name' is not named Luxicon-<marketing>-<build>.dmg" >&2
  exit 1
fi
base="${dmg_name%.dmg}"
build="${base##*-}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# generate_appcast scans a directory of archives and merges into an appcast.xml
# already in that directory, so seed it with the published feed to keep history.
cp "$DMG_PATH" "$work/"
if [ -f "$PAGES_DIR/appcast.xml" ]; then
  cp "$PAGES_DIR/appcast.xml" "$work/appcast.xml"
fi

# Release notes Markdown -> HTML. cmark when available; otherwise escaped <pre>.
render_notes() {
  if command -v cmark >/dev/null 2>&1; then
    cmark "$RELEASE_NOTES_MD"
  else
    echo '<pre>'
    sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' "$RELEASE_NOTES_MD"
    echo '</pre>'
  fi
}
# Beside the DMG with the same base name, so generate_appcast attaches it to the
# new item. A fragment (no DOCTYPE/body) and --embed-release-notes: the notes go
# into the item's <description>, not a releaseNotesLink under the download prefix.
render_notes > "$work/$base.html"
# A standalone copy for the Pages site, copied in only once every guard passes.
mkdir -p "$work/pages-notes"
{ echo '<!doctype html><meta charset="utf-8"><title>Luxicon for Mac release notes</title><body>'
  cat "$work/$base.html"
  echo '</body>'; } > "$work/pages-notes/$base.html"

# --maximum-versions 0 keeps every item; Sparkle's default (3) would trim the
# oldest from the fourth release on.
gen_args=(--download-url-prefix "$DOWNLOAD_URL_PREFIX"
          --link "https://github.com/DavidsonCollege/luxicon/releases"
          --embed-release-notes
          --maximum-versions 0)
# The same key source for generate_appcast and (rotation only) sign_update.
if [ -n "${ED_KEY_FILE:-}" ]; then
  [ -f "$ED_KEY_FILE" ] || { echo "error: ED_KEY_FILE '$ED_KEY_FILE' is not a file" >&2; exit 1; }
  key_args=(--ed-key-file "$ED_KEY_FILE")
else
  key_args=(--account "$KEYCHAIN_ACCOUNT")
fi
"$SPARKLE_BIN/generate_appcast" "${gen_args[@]}" "${key_args[@]}" "$work"

out="$work/appcast.xml"
if [ ! -s "$out" ]; then
  echo "Refusing to publish: generate_appcast wrote no appcast." >&2
  exit 1
fi

# Guard 1: the new item (this build's sparkle:version) exists exactly once and
# carries an EdDSA signature. generate_appcast exits 0 and writes the item
# WITHOUT sparkle:edSignature when the app's SUPublicEDKey doesn't match the
# signing key (a wrong key, or a key rotation), and every client would refuse
# that update.
new_item() {
  awk -v want="<sparkle:version>$build</sparkle:version>" '
    /<item>/ { buf = ""; inside = 1 }
    inside { buf = buf $0 "\n" }
    /<\/item>/ { inside = 0; if (index(buf, want)) { printf "%s", buf; n++ } }
    END { exit (n == 1 ? 0 : 1) }' "$1"
}
has_signature() { grep -qE 'sparkle:edSignature="[^"]+"' <<<"$1"; }
item="$(new_item "$out")" || {
  echo "Refusing to publish: the generated appcast doesn't have exactly one item with sparkle:version $build (the build in $dmg_name)." >&2
  exit 1
}
if [ -n "$ROTATION_SIGN" ]; then
  if has_signature "$item"; then
    echo "Refusing: ROTATION_SIGN is set but generate_appcast already signed build $build, so the app's SUPublicEDKey matches the signing key; there's nothing to rotate." >&2
    exit 1
  fi
  # Sign with the current (old) key: installed apps hold the old public key and
  # verify this release with it; the release itself carries the new key.
  sig="$("$SPARKLE_BIN/sign_update" "${key_args[@]}" -p "$work/$dmg_name")"
  if [[ ! "$sig" =~ ^[A-Za-z0-9+/]+=*$ ]]; then
    echo "Refusing to publish: sign_update didn't print a signature." >&2
    exit 1
  fi
  "$SPARKLE_BIN/sign_update" "${key_args[@]}" --verify "$work/$dmg_name" "$sig" >/dev/null
  # Put it on the first <enclosure> of this build's item (generate_appcast made
  # no delta enclosures: the work dir holds only this DMG).
  tmp="$work/appcast.rotation.xml"
  awk -v want="<sparkle:version>$build</sparkle:version>" -v sig="$sig" '
    /<item>/ { buf = ""; inside = 1 }
    inside {
      buf = buf $0 "\n"
      if ($0 ~ /<\/item>/) {
        inside = 0
        if (index(buf, want)) sub(/<enclosure /, "<enclosure sparkle:edSignature=\"" sig "\" ", buf)
        printf "%s", buf
      }
      next
    }
    { print }' "$out" > "$tmp"
  mv "$tmp" "$out"
  item="$(new_item "$out")" || { echo "Refusing to publish: lost build $build's item while signing it." >&2; exit 1; }
  echo "ROTATION_SIGN: signed build $build with the current (old) key."
fi
if ! has_signature "$item"; then
  echo "Refusing to publish: build $build's item has no sparkle:edSignature. The app's SUPublicEDKey doesn't match the signing key (see generate_appcast's warning above). If this is a key rotation release, see docs/releasing.md, \"Rotating the key\"." >&2
  exit 1
fi

# Guard 2: never publish a feed that lost history.
count_items() { grep -c '<item>' "$1" || true; }
new_items="$(count_items "$out")"
old_items=0
if [ -f "$PAGES_DIR/appcast.xml" ]; then
  old_items="$(count_items "$PAGES_DIR/appcast.xml")"
fi
if [ "$new_items" -lt 1 ] || [ "$new_items" -lt "$old_items" ]; then
  echo "Refusing to publish: generated appcast has $new_items item(s); the existing one has $old_items." >&2
  exit 1
fi
# A count can stay equal while an item is swapped out, so every sparkle:version
# in the published feed must still be in the new one.
versions() { grep -oE '<sparkle:version>[^<]*</sparkle:version>' "$1" | sed -E 's#</?sparkle:version>##g' | sort -u || true; }
if [ -f "$PAGES_DIR/appcast.xml" ]; then
  missing="$(comm -23 <(versions "$PAGES_DIR/appcast.xml") <(versions "$out"))"
  if [ -n "$missing" ]; then
    echo "Refusing to publish: generated appcast dropped sparkle:version(s): $(tr '\n' ' ' <<<"$missing")" >&2
    exit 1
  fi
fi

# Guard 3: every enclosure points at this release or an earlier mac-v* release.
urls="$(grep -oE 'enclosure url="[^"]*"' "$out" | sed -E 's/^enclosure url="(.*)"$/\1/' || true)"
if [ -z "$urls" ]; then
  echo "Refusing to publish: generated appcast has no enclosure URLs." >&2
  exit 1
fi
bad=0
while IFS= read -r url; do
  case "$url" in
    "$DOWNLOAD_URL_PREFIX"*|"$OLDER_URL_PREFIX"*) ;;
    *) echo "Refusing to publish: unexpected enclosure URL: $url" >&2; bad=1 ;;
  esac
done <<<"$urls"
[ "$bad" -eq 0 ] || exit 1

mkdir -p "$PAGES_DIR/release-notes"
notes_html="$PAGES_DIR/release-notes/$base.html"
cp "$work/pages-notes/$base.html" "$notes_html"
cp "$out" "$PAGES_DIR/appcast.xml"
echo "Wrote $PAGES_DIR/appcast.xml ($new_items item(s)) and $notes_html"
