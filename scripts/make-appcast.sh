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
# Writes $PAGES_DIR/appcast.xml and $PAGES_DIR/release-notes/Luxicon-<m>-<b>.html.
set -euo pipefail

: "${DMG_PATH:?}"; : "${RELEASE_NOTES_MD:?}"; : "${SPARKLE_BIN:?}"
: "${DOWNLOAD_URL_PREFIX:?}"; : "${PAGES_DIR:?}"

KEYCHAIN_ACCOUNT="edu.davidson.luxicon.mac"
# Enclosures of earlier releases may point at any earlier mac-v* release.
OLDER_URL_PREFIX="https://github.com/DavidsonCollege/luxicon/releases/download/mac-v"

[ -f "$DMG_PATH" ] || { echo "error: DMG_PATH '$DMG_PATH' is not a file" >&2; exit 1; }
[ -f "$RELEASE_NOTES_MD" ] || { echo "error: RELEASE_NOTES_MD '$RELEASE_NOTES_MD' is not a file" >&2; exit 1; }
[ -x "$SPARKLE_BIN/generate_appcast" ] || { echo "error: no generate_appcast in '$SPARKLE_BIN'" >&2; exit 1; }
[ -d "$PAGES_DIR" ] || { echo "error: PAGES_DIR '$PAGES_DIR' is not a directory" >&2; exit 1; }

dmg_name="$(basename "$DMG_PATH")"
if [[ ! "$dmg_name" =~ ^Luxicon-[0-9]+(\.[0-9]+)*-[0-9]+\.dmg$ ]]; then
  echo "error: '$dmg_name' is not named Luxicon-<marketing>-<build>.dmg" >&2
  exit 1
fi
base="${dmg_name%.dmg}"

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
# A standalone copy for the Pages site.
mkdir -p "$PAGES_DIR/release-notes"
notes_html="$PAGES_DIR/release-notes/$base.html"
{ echo '<!doctype html><meta charset="utf-8"><title>Luxicon for Mac release notes</title><body>'
  cat "$work/$base.html"
  echo '</body>'; } > "$notes_html"

gen_args=(--download-url-prefix "$DOWNLOAD_URL_PREFIX"
          --link "https://github.com/DavidsonCollege/luxicon/releases"
          --embed-release-notes)
if [ -n "${ED_KEY_FILE:-}" ]; then
  [ -f "$ED_KEY_FILE" ] || { echo "error: ED_KEY_FILE '$ED_KEY_FILE' is not a file" >&2; exit 1; }
  gen_args+=(--ed-key-file "$ED_KEY_FILE")
else
  gen_args+=(--account "$KEYCHAIN_ACCOUNT")
fi
"$SPARKLE_BIN/generate_appcast" "${gen_args[@]}" "$work"

out="$work/appcast.xml"
if [ ! -s "$out" ]; then
  echo "Refusing to publish: generate_appcast wrote no appcast." >&2
  exit 1
fi

# Guard 1: never publish a feed that lost history.
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

# Guard 2: every enclosure points at this release or an earlier mac-v* release.
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

cp "$out" "$PAGES_DIR/appcast.xml"
echo "Wrote $PAGES_DIR/appcast.xml ($new_items item(s)) and $notes_html"
