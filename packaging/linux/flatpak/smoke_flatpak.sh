#!/usr/bin/env bash
# Smoke test of the installed org.lastbook.Lastbook Flatpak, following packaging/linux/smoke_deb.sh:
#   decoders in the sandbox, window with a library, a video plays, map, second copy exits, no listening sockets,
#   Ctrl+Q ends the app and its WebKit processes, setup with no library, the library is left in place.
# Runs on a private Xvfb display, so nothing appears on the real screen. Needs Xvfb, openbox, xdotool, ImageMagick and
# iproute2 on PATH, and the Small pack unpacked in the app's data folder (see README.md).
#   bash packaging/linux/flatpak/smoke_flatpak.sh [shots-folder]
# Clicks use fixed positions in a 1280x860 window, as smoke_deb.sh does: a layout change moves them.
set -uo pipefail
APP=org.lastbook.Lastbook
OUT="${1:-shots}"
DATA="$HOME/.var/app/$APP/data/Lastbook"
DISP=:99
mkdir -p "$OUT"
FAILED=0

pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; FAILED=1; }
running() { flatpak ps --columns=application | grep -qx "$APP"; }
x() { DISPLAY=$DISP "$@"; }
start() { (env -u WAYLAND_DISPLAY DISPLAY=$DISP flatpak run --nosocket=wayland --socket=x11 $APP >"$OUT/$1.log" 2>&1 &); }
window() { for _ in $(seq 40); do x xdotool search --name '^Lastbook$' >/dev/null 2>&1 && { sleep 4; fit; return 0; }; sleep 1; done; return 1; }
fit() { for w in $(x xdotool search --name '^Lastbook$'); do x xdotool windowmove "$w" 0 0 windowsize "$w" 1280 860; done; sleep 2; }
shot() { x import -window root "$OUT/$1.png"; }
click() { x xdotool mousemove "$1" "$2" click 1; sleep "${3:-4}"; }
quit() { for w in $(x xdotool search --name '^Lastbook$'); do x xdotool windowactivate --sync "$w" key ctrl+q 2>/dev/null; done
         for _ in $(seq 15); do running || return 0; sleep 1; done; return 1; }
app_pids() { ps -eo pid=,comm=,args= | awk '($2 == "python3" && /\/app\/lastbook\/lastbook\.py/) || $2 ~ /^WebKit/ { print $1 }'; }
frames_differ() {  # two crops of the player and its clock, two seconds apart (a still slide still moves the clock)
  x import -window root -crop 583x327+301+142 "$OUT/.a.png"; sleep 2; x import -window root -crop 583x327+301+142 "$OUT/.b.png"
  [ "$(compare -metric AE "$OUT/.a.png" "$OUT/.b.png" null: 2>&1 | cut -d' ' -f1 | cut -d. -f1)" -gt 0 ]; }

running && { echo "Lastbook is open: quit it first"; exit 2; }
[ -f "$DATA/LastbookData/library-data/catalog.json" ] || { echo "no library in $DATA/LastbookData (see README.md)"; exit 2; }
echo "== $(flatpak info $APP | grep -E 'Version|Runtime|Commit' | tr -s ' ' | paste -sd' ')"

Xvfb $DISP -screen 0 1360x900x24 -nolisten tcp >"$OUT/xvfb.log" 2>&1 & XVFB=$!
restore() { [ -e "$DATA/LastbookData.smoke-aside" ] && mv "$DATA/LastbookData.smoke-aside" "$DATA/LastbookData"; kill "$XVFB" "${WM:-}" 2>/dev/null; rm -f "$OUT"/.?.png; }
trap restore EXIT
sleep 2; x openbox >/dev/null 2>&1 & WM=$!; sleep 1

echo "== 1. decoders in the sandbox: one AV1 and one H.264 video from the library, decoded to the end"
flatpak run --command=sh $APP -c '
  L=$XDG_DATA_HOME/Lastbook/LastbookData/library-data
  for want in AV1 H.264; do
    f=$(find "$L/videos" "$L/videos-external" -type f -name "*.mp4" 2>/dev/null | while read -r v; do
          gst-discoverer-1.0 "$v" 2>&1 | grep -q "video #[0-9]*: $want" && { echo "$v"; break; }; done)
    [ -n "$f" ] || { echo "FAIL  no $want video in the library"; continue; }
    uri=$(python3 -I -c "import pathlib, sys; print(pathlib.Path(sys.argv[1]).as_uri())" "$f")
    if timeout 300 gst-launch-1.0 -q playbin uri="$uri" video-sink="fakesink sync=false" audio-sink="fakesink sync=false" >/dev/null 2>&1
    then echo "PASS  $want decodes: $(basename "$f")"; else echo "FAIL  $want does not decode: $(basename "$f")"; fi
  done' | tee "$OUT/decoders.txt"
grep -q '^FAIL' "$OUT/decoders.txt" && FAILED=1

echo "== 2. with the library"
start run-library
window && pass "window opens" || fail "no window"
shot 01-library-home
click 426 505 5; shot 02-video-opened                     # the first card of "Picked for the guides"
click 592 306 8; shot 03-video-playing
frames_differ && pass "a video plays (picture or clock moves)" || fail "the video does not move"
click 80 165 8; shot 04-map
click 1143 78 1; x xdotool type --delay 40 "boil water"; x xdotool key Return; sleep 6; shot 05-search
click 627 657 6; shot 06-reader                           # the first page in the results

t=$(date +%s); env -u WAYLAND_DISPLAY DISPLAY=$DISP timeout 30 flatpak run --nosocket=wayland --socket=x11 $APP >"$OUT/second.log" 2>&1
rc=$?; [ $rc = 0 ] && [ $(( $(date +%s) - t )) -lt 10 ] && pass "a second copy exits at once" || fail "second copy: exit $rc after $(( $(date +%s) - t )) s"

pids=$(app_pids | paste -sd'|')
if [ -n "$pids" ] && ss -ltunp 2>/dev/null | grep -qE "pid=($pids),"; then fail "a Lastbook process listens:"; ss -ltunp | grep -E "pid=($pids),"
else pass "no listening sockets ($(echo "$pids" | tr '|' ' ' | wc -w) app and WebKit processes)"; fi

quit && [ -z "$(app_pids)" ] && pass "Ctrl+Q ends the app and its WebKit processes" || fail "still running after Ctrl+Q"
tail -1 "$DATA/LastbookData/derived/logs/lastbook.log" | sed 's/^/      log: /'

echo "== 3. no library: setup"
mv "$DATA/LastbookData" "$DATA/LastbookData.smoke-aside"
start run-setup
window && pass "setup opens with no library" || fail "no setup window"
shot 07-setup
quit || fail "setup did not quit"
mv "$DATA/LastbookData.smoke-aside" "$DATA/LastbookData"
[ -f "$DATA/LastbookData/library-data/catalog.json" ] && pass "library kept" || fail "LIBRARY MISSING"

echo "== screenshots in $OUT"
[ $FAILED = 0 ] && echo "== all checks passed" || { echo "== some checks FAILED"; exit 1; }
