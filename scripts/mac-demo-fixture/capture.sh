#!/usr/bin/env bash
# Capture the Mac app's marketing screenshots from the fictional demo library.
#
#   scripts/mac-demo-fixture/capture.sh <Debug Luxicon.app> <work dir> [out dir]
#
# <work dir>  scratch directory for the generated fixture (lib/, store/), the
#             simulated microphone audio, and logs. Never ~/Luxicon.
# [out dir]   defaults to marketing/screenshots/mac
#
# Each shot regenerates the fixture (generate.py), so a recording left behind
# by one launch is never recovered into the next. The app is launched with
# `open -n` so its window is active (focused styling) in the capture; only
# the Debug app at the given path is ever terminated. The recording shots use
# -simulateMicrophone (a `say`-generated file) and -simulateCaptions: the
# real microphone is never opened and no permission prompt appears.
# Needs Screen Recording permission for the terminal running it.
set -euo pipefail

if [[ $# -lt 2 ]]; then
    sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
    exit 64
fi
APP=$(cd "$1" && pwd -P)
WORK=$2
HERE=$(cd "$(dirname "$0")" && pwd -P)
OUT=${3:-$HERE/../../marketing/screenshots/mac}
BIN="$APP/Contents/MacOS/Luxicon"
SIZE=1512x982
PERSON=4ED4DB9D-1597-49A6-9DEB-8823C8326125    # Priya Shah
SESSION=216982DA-FBB6-4238-B62C-22F395056E23   # the featured session

[[ -x "$BIN" ]] || { echo "error: no executable at $BIN" >&2; exit 1; }
# Release builds ignore -libraryPath/-storePath and would open the real library.
grep -aqF -- "-seedSessionFromWAV" "$APP"/Contents/MacOS/* 2>/dev/null \
    || { echo "error: $APP is not a DEBUG build; refusing to run" >&2; exit 1; }
if pgrep -f "$BIN" > /dev/null; then
    echo "error: $BIN is already running" >&2; exit 1
fi
mkdir -p "$WORK" "$OUT"
WORK=$(cd "$WORK" && pwd -P)
OUT=$(cd "$OUT" && pwd -P)

MIC="$WORK/simulated-mic.wav"
if [[ ! -f $MIC ]]; then
    # The caption text, spoken, so the level meter moves like speech.
    python3 "$HERE/generate.py" "$WORK" > /dev/null
    say -o "$MIC" --file-format=WAVE --data-format=LEI16@16000 -f "$WORK/captions.txt"
fi

# shot <png name> <seconds to wait after the window is reported> <app args...>
shot() {
    local name=$1 settle=$2
    shift 2
    python3 "$HERE/generate.py" "$WORK" > /dev/null
    local log="$WORK/$name.log"
    rm -f "$log"
    open -n -a "$APP" --stdout "$log" --stderr "$WORK/$name.err" --args \
        -libraryPath "$WORK/lib" -storePath "$WORK/store" -windowSize "$SIZE" -printWindowID "$@"
    local id=""
    for _ in $(seq 1 100); do
        id=$(sed -n 's/^WINDOW_ID //p' "$log" 2> /dev/null | head -1)
        [[ -n $id ]] && break
        sleep 0.2
    done
    if [[ -z $id || $id == none ]]; then
        echo "FAIL $name (no window id)" >&2
        pkill -f "$BIN" || true
        return 1
    fi
    sleep "$settle"
    screencapture -x -o -l "$id" "$OUT/$name"
    pkill -f "$BIN" || true
    for _ in $(seq 1 50); do pgrep -f "$BIN" > /dev/null || break; sleep 0.2; done
    echo "ok   $OUT/$name"
}

shot 1-main.png 1 -route "session:$SESSION" -appearance light
shot 2-main-dark.png 1 -route "session:$SESSION" -appearance dark
shot 3-recording.png 20 -route "record:$PERSON" -appearance light \
    -simulateMicrophone "$MIC" -simulateCaptions "$WORK/captions.txt"
shot 4-muted.png 9 -route "record:$PERSON" -appearance light \
    -simulateMicrophone "$MIC" -simulateCaptions "$WORK/captions.txt" -simulateMuteAt 7

# Committed files: keep each under ~2 MB.
for png in "$OUT"/*.png; do
    if [[ $(stat -f %z "$png") -gt 2000000 ]]; then
        echo "note $png is over 2 MB" >&2
    fi
done
