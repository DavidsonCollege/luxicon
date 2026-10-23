#!/usr/bin/env bash
# Screenshot every Mac app screen at each desktop window size, in light and
# dark, for layout QA (docs/superpowers/specs/2026-10-22-mac-app-design.md,
# "Desktop resolution testing").
#
#   scripts/mac-screenshots.sh <app path> <fixture dir> <out dir> [route-label ...]
#
# <app path>     a DEBUG Luxicon.app (the -route/-windowSize hooks are DEBUG-only)
# <fixture dir>  holds lib/ (a copy of a library folder) and store/ (a store
#                with at least one processed Mac session). Never point this at
#                ~/Luxicon or the real store: launches may write to both.
# <out dir>      receives <route>-<w>x<h>-<appearance>.png
# route-label    optional subset of: sidebar-all person session librarySession
#                record settings onboarding (default: all seven)
#
# IDs come from the fixture's store.json (its first session and that
# session's person) and the largest phone file in lib/; override with
# PERSON_ID, SESSION_ID, LIBRARY_KEY. SIZES and APPEARANCES override the
# defaults (space-separated).
#
# Needs Screen Recording permission for the terminal running it. Fixture
# data and screenshots can contain real transcripts: keep them out of git.
set -euo pipefail

if [[ $# -lt 3 ]]; then
    sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'
    exit 64
fi

APP=$1
FIXTURE=$2
OUT=$3
shift 3
BIN="$APP/Contents/MacOS/Luxicon"
STORE_JSON="$FIXTURE/store/store.json"
[[ -x "$BIN" ]] || { echo "error: no executable at $BIN" >&2; exit 1; }
# Refuse a Release app: it ignores -libraryPath/-storePath and would open the
# real store and ~/Luxicon. DebugLaunchOptions (DEBUG-only) is the only code
# with this flag name; Debug builds may keep it in Luxicon.debug.dylib.
grep -aqF -- "-seedSessionFromWAV" "$APP"/Contents/MacOS/* 2>/dev/null \
    || { echo "error: $APP is not a DEBUG build (no DebugLaunchOptions); refusing to run" >&2; exit 1; }
[[ -f "$STORE_JSON" ]] || { echo "error: no $STORE_JSON (generate the fixture store first)" >&2; exit 1; }
[[ "$(cd "$FIXTURE/lib" && pwd -P)" != "$(cd ~/Luxicon 2>/dev/null && pwd -P || echo none)" ]] \
    || { echo "error: fixture lib is ~/Luxicon" >&2; exit 1; }
mkdir -p "$OUT"

read -r -a SIZES <<< "${SIZES:-900x600 1280x800 1512x982 1920x1080 2560x1440}"
read -r -a APPEARANCES <<< "${APPEARANCES:-light dark}"

SESSION_ID=${SESSION_ID:-$(plutil -extract sessions.0.id raw "$STORE_JSON")}
PERSON_ID=${PERSON_ID:-$(plutil -extract sessions.0.personId raw "$STORE_JSON")}
if [[ -z "${LIBRARY_KEY:-}" ]]; then
    MAC_FILE=$(plutil -extract sessions.0.libraryFileName raw "$STORE_JSON" 2>/dev/null || true)
    LIBRARY_KEY=$(cd "$FIXTURE/lib" && ls -S -- *.json | grep -vxF "$MAC_FILE" | head -1)
fi

route_arg() {
    case $1 in
        sidebar-all) echo "sidebar:all" ;;
        person) echo "person:$PERSON_ID" ;;
        session) echo "session:$SESSION_ID" ;;
        librarySession) echo "librarySession:$LIBRARY_KEY" ;;
        record) echo "record:$PERSON_ID" ;;
        settings) echo "settings" ;;
        onboarding) echo "onboarding" ;;
        *) echo "error: unknown route label $1" >&2; return 1 ;;
    esac
}

if [[ $# -gt 0 ]]; then ROUTES=("$@"); else
    ROUTES=(sidebar-all person session librarySession record settings onboarding)
fi

wait_for_no_instance() {
    for _ in $(seq 1 50); do
        pgrep -f "$BIN" > /dev/null || return 0
        sleep 0.2
    done
    echo "error: another instance of $BIN is still running" >&2
    exit 1
}

LOG=$(mktemp -t luxicon-shot)
trap 'rm -f "$LOG"' EXIT
count=0
failed=0
for label in "${ROUTES[@]}"; do
    route=$(route_arg "$label")
    for size in "${SIZES[@]}"; do
        for appearance in "${APPEARANCES[@]}"; do
            png="$OUT/$label-$size-$appearance.png"
            wait_for_no_instance
            extra=()
            [[ $label == record ]] && extra=(-noMicrophone)
            "$BIN" -libraryPath "$FIXTURE/lib" -storePath "$FIXTURE/store" \
                -route "$route" -windowSize "$size" -appearance "$appearance" \
                -printWindowID ${extra[@]+"${extra[@]}"} > "$LOG" 2>&1 &
            pid=$!
            id=""
            for _ in $(seq 1 100); do
                id=$(sed -n 's/^WINDOW_ID //p' "$LOG" | head -1)
                [[ -n $id ]] && break
                kill -0 "$pid" 2> /dev/null || break
                sleep 0.2
            done
            if [[ -n $id && $id != none ]]; then
                sleep 1   # let the last frame draw
                if screencapture -x -o -l "$id" "$png"; then
                    count=$((count + 1))
                    echo "ok   $png"
                else
                    failed=$((failed + 1))
                    echo "FAIL $png (screencapture)" >&2
                fi
            else
                failed=$((failed + 1))
                echo "FAIL $png (no window id; log follows)" >&2
                sed 's/^/     /' "$LOG" >&2
            fi
            kill "$pid" 2> /dev/null || true
            wait "$pid" 2> /dev/null || true
        done
    done
done
echo "$count screenshots in $OUT, $failed failed"
[[ $failed -eq 0 ]]
