#!/bin/sh
# Offline harness for eink-wallpaper.sh: no Kindle, no network, no framebuffer.
#
# The scriptlet is driven through stubs: a curl that serves the fixture, an
# fbink that records what the panel was asked to draw (and fails when the file
# is not there, which the real scriptlet would swallow), and a lipc-set-prop
# that records the powerd/appmgrd calls.
#
# Usage:
#   sh tests/smoke.sh
#
# Exits 0 when every check passes, 1 otherwise. Needs `timeout` and `mkfifo`.

HERE=$(dirname "$0")
ROOT=$(cd "$HERE/.." && pwd)
SCRIPT="$ROOT/eink-wallpaper.sh"
FIXTURE="$ROOT/tests/fixtures/feed.json"
REAL_PATH="$PATH"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/unsplash-smoke.XXXXXX")
BIN="$WORK/bin"
LOG_DIR="$WORK/log"
FIFO="$WORK/touch.fifo"

WRITER=""
cleanup() {
    [ -n "$WRITER" ] && kill "$WRITER" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

for t in timeout mkfifo sh; do
    if ! command -v "$t" >/dev/null 2>&1; then
        echo "missing required tool: $t" >&2
        exit 1
    fi
done

mkdir -p "$BIN" "$LOG_DIR"
mkfifo "$FIFO"

# --- stubs -------------------------------------------------------------------

cat > "$BIN/curl" <<'STUB'
#!/bin/sh
# Serves the fixture feed and one fake photo file per photo id.
echo "curl $*" >> "$LOG_DIR/curl.log"
dest=""
prev=""
last=""
for a in "$@"; do
    [ "$prev" = "-o" ] && dest="$a"
    prev="$a"
    last="$a"
done
case "$last" in
    *images.unsplash.com/photo-*)
        [ "$FAIL_IMAGES" = "1" ] && exit 22
        id=$(printf '%s\n' "$last" | sed 's|.*/||; s|[?].*||')
        printf 'PHOTO:%s\n' "$id" > "$dest" || exit 23
        ;;
    *unsplash.com*)
        [ "$FAIL_FEED" = "1" ] && exit 22
        cp "$FEED_SRC" "$dest" || exit 23
        ;;
    *)
        exit 7
        ;;
esac
exit 0
STUB

cat > "$BIN/fbink" <<'STUB'
#!/bin/sh
# Records what the panel was asked to draw. Exits non-zero on a file the real
# fbink would refuse, because the scriptlet redirects fbink to /dev/null.
line="fbink $*"
file=""
clear=0
draw=0
text=0
for a in "$@"; do
    case "$a" in
        -c) clear=1 ;;
        -y) text=1 ;;
        file=*) draw=1; file=${a#file=}; file=${file%%,*} ;;
    esac
done
if [ "$draw" = "1" ]; then
    if [ ! -s "$file" ]; then
        echo "MISSING_IMAGE $file" >> "$LOG_DIR/fbink.log"
        echo "$line" >> "$LOG_DIR/fbink.log"
        exit 1
    fi
    if [ "$clear" = "1" ]; then
        echo "CLEAR_AND_DRAW $file" >> "$LOG_DIR/shown.log"
    else
        echo "DRAW_ONLY $file" >> "$LOG_DIR/shown.log"
    fi
elif [ "$text" = "1" ]; then
    echo "TEXT_CALL" >> "$LOG_DIR/fbink.log"
elif [ "$clear" = "1" ]; then
    echo "CLEAR_ONLY" >> "$LOG_DIR/fbink.log"
fi
echo "$line" >> "$LOG_DIR/fbink.log"
exit 0
STUB

cat > "$BIN/lipc-set-prop" <<'STUB'
#!/bin/sh
echo "lipc $*" >> "$LOG_DIR/lipc.log"
exit 0
STUB

chmod +x "$BIN/curl" "$BIN/fbink" "$BIN/lipc-set-prop"

# --- harness -----------------------------------------------------------------

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok       %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAILED   %s\n' "$1"; }

# check <name> <0|1>
check() { if [ "$2" = "0" ]; then ok "$1"; else bad "$1"; fi; }

# saw <file> <pattern> / nosaw <file> <pattern>
saw()   { if grep -qE -- "$2" "$1" 2>/dev/null; then echo 0; else echo 1; fi; }
nosaw() { if grep -qE -- "$2" "$1" 2>/dev/null; then echo 1; else echo 0; fi; }
# count <file> <pattern>
count() { grep -cE -- "$2" "$1" 2>/dev/null | tr -d ' '; }

reset_logs() {
    for f in curl.log shown.log fbink.log lipc.log; do
        : > "$LOG_DIR/$f"
    done
}

# run - uses APP_DIR_T, INTERVAL, MAX_RUN, KEEP, ERROR_WAIT, TOUCH_DEV,
#        FBINK_T, CONF_T, FAIL_FEED, FAIL_IMAGES from the caller.
run() {
    reset_logs
    mkdir -p "$APP_DIR_T"
    (
        cd "$WORK" || exit 1
        PATH="$BIN:$REAL_PATH" \
        APP_DIR="$APP_DIR_T" \
        PANEL="$PANEL" \
        INTERVAL="$INTERVAL" \
        MAX_RUN="$MAX_RUN" \
        KEEP="$KEEP" \
        ERROR_WAIT="$ERROR_WAIT" \
        TOUCH_DEV="$TOUCH_DEV" \
        FBINK="$FBINK_T" \
        CONF="$CONF_T" \
        FEED_SRC="$FIXTURE" \
        FAIL_FEED="$FAIL_FEED" \
        FAIL_IMAGES="$FAIL_IMAGES" \
        LOG_DIR="$LOG_DIR" \
        timeout 60 sh "$SCRIPT"
    ) > "$APP_DIR_T/stdout" 2>&1
    echo "$?" > "$APP_DIR_T/exit"
}

exit_of() { cat "$APP_DIR_T/exit"; }
shown_files() { sed 's/^[A-Z_]* //' "$LOG_DIR/shown.log"; }

# Fresh defaults for every scenario.
defaults() {
    PANEL=600x800
    INTERVAL=0
    MAX_RUN=0
    KEEP=40
    ERROR_WAIT=1
    TOUCH_DEV=""
    CONF_T=/dev/null
    FAIL_FEED=0
    FAIL_IMAGES=0
    FBINK_T="$BIN/fbink"
}

echo "=== eink-wallpaper: offline smoke suite ==="
echo

# --- 1. rotation, rendering, feed parsing ------------------------------------

echo "--- rotation, rendering, feed parsing ---"
EXPECT_LIST="https://images.unsplash.com/photo-1600000000001-aaaa
https://images.unsplash.com/photo-1600000000002-bbbb
https://images.unsplash.com/photo-1600000000003-cccc"
defaults
APP_DIR_T="$WORK/rot"
MAX_RUN=3
run

check "a bounded run exits 0" \
    "$([ "$(exit_of)" = "0" ] && echo 0 || echo 1)"
check "three photos reach the panel" \
    "$([ "$(count "$LOG_DIR/shown.log" '^CLEAR_AND_DRAW ')" = "3" ] && echo 0 || echo 1)"
check "every photo is cleared and drawn in a single fbink call" \
    "$([ "$(count "$LOG_DIR/shown.log" '^DRAW_ONLY ')" = "0" ] && echo 0 || echo 1)"
check "no draw of a file that is not there" \
    "$(nosaw "$LOG_DIR/fbink.log" 'MISSING_IMAGE')"
check "the three photos are distinct" \
    "$([ "$(shown_files | awk '!seen[$0]++' | wc -l | tr -d ' ')" = "3" ] && echo 0 || echo 1)"

BYTES_BAD=0
for f in $(shown_files); do
    id=$(basename "$f")
    id=${id%.*}
    [ "$(head -n 1 "$f")" = "PHOTO:$id" ] || BYTES_BAD=1
done
check "each drawn file holds the photo its own URL asked for" "$BYTES_BAD"

check "the feed list holds the three public photos" \
    "$([ "$(count "$APP_DIR_T/feed.txt" '.' )" = "3" ] && echo 0 || echo 1)"
check "premium and s3 variants never enter the list" \
    "$(nosaw "$APP_DIR_T/feed.txt" 'premium_photo|small_s3|s3\.')"
check "the public feed uses the default search terms" \
    "$(saw "$LOG_DIR/curl.log" 'napi/search/photos[?]query=nature%20animals%20abstract')"
check "each photo is downloaded once, the next one is prefetched" \
    "$([ "$(count "$LOG_DIR/curl.log" 'images.unsplash.com/photo-')" = "3" ] && echo 0 || echo 1)"
check "the shuffled list is exactly the three public photos" \
    "$([ "$(sort "$APP_DIR_T/feed.txt")" = "$EXPECT_LIST" ] && echo 0 || echo 1)"

# --- 2. warm cache ------------------------------------------------------------

echo
echo "--- warm cache ---"
FAIL_IMAGES=1
MAX_RUN=3
run

check "a warm cache still turns with the image host down" \
    "$([ "$(exit_of)" = "0" ] && echo 0 || echo 1)"
check "three cached photos reach the panel" \
    "$([ "$(count "$LOG_DIR/shown.log" '^CLEAR_AND_DRAW ')" = "3" ] && echo 0 || echo 1)"
check "nothing is downloaded when the cache is warm" \
    "$([ "$(count "$LOG_DIR/curl.log" 'images.unsplash.com/photo-')" = "0" ] && echo 0 || echo 1)"

# --- 3. feed down, cache warm -------------------------------------------------

echo
echo "--- feed down, cache warm ---"
FAIL_FEED=1
MAX_RUN=2
run

check "a failed feed falls back to the cached list" \
    "$(saw "$APP_DIR_T/unsplash.log" 'reusing the cached list')"
check "the fallback run still shows photos" \
    "$([ "$(count "$LOG_DIR/shown.log" '^CLEAR_AND_DRAW ')" = "2" ] && echo 0 || echo 1)"

# --- 4. cold start with nothing reachable ------------------------------------

echo
echo "--- cold start, no network ---"
defaults
APP_DIR_T="$WORK/cold"
FAIL_FEED=1
ERROR_WAIT=1
run

check "a cold start with no network exits 1" \
    "$([ "$(exit_of)" = "1" ] && echo 0 || echo 1)"
check "the failure is logged" \
    "$(saw "$APP_DIR_T/unsplash.log" 'no cached list')"
check "the message goes to the panel" \
    "$(saw "$LOG_DIR/fbink.log" 'TEXT_CALL')"
check "nothing is drawn as a photo" \
    "$([ "$(count "$LOG_DIR/shown.log" '^CLEAR_AND_DRAW ')" = "0" ] && echo 0 || echo 1)"

# --- 5. the minute, and the way out ------------------------------------------

echo
echo "--- interval and tap ---"
defaults
APP_DIR_T="$WORK/rot"
PANEL=600x800
INTERVAL=60
MAX_RUN=0
FAIL_FEED=1
FAIL_IMAGES=1
TOUCH_DEV="$FIFO"
BEFORE=$(date +%s)
( sleep 2; printf '0123456789abcdef' > "$FIFO" ) &
WRITER=$!
run
AFTER=$(date +%s)
kill "$WRITER" 2>/dev/null
WRITER=""

check "a tap ends the run" \
    "$([ "$(exit_of)" = "0" ] && echo 0 || echo 1)"
check "the tap cuts the 60s interval short" \
    "$([ "$((AFTER - BEFORE))" -lt 30 ] && echo 0 || echo 1)"
check "one photo was on the panel" \
    "$([ "$(count "$LOG_DIR/shown.log" '^CLEAR_AND_DRAW ')" = "1" ] && echo 0 || echo 1)"
check "leaving hands the screen back to the library" \
    "$(saw "$LOG_DIR/lipc.log" 'appmgrd start app://com.lab126.booklet.home')"
check "leaving re-enables the screensaver" \
    "$(saw "$LOG_DIR/lipc.log" 'preventScreenSaver 0')"

# --- 6. the key, and the request it buys -------------------------------------

echo
echo "--- api key ---"
defaults
APP_DIR_T="$WORK/key"
mkdir -p "$APP_DIR_T"
CONF_T="$APP_DIR_T/unsplash.conf"
printf 'UNSPLASH_ACCESS_KEY=test-key-123\n' > "$CONF_T"
MAX_RUN=1
run

check "a key in unsplash.conf asks the official search endpoint" \
    "$(saw "$LOG_DIR/curl.log" 'api.unsplash.com/search/photos[?]query=nature%20animals%20abstract')"
check "the key travels in the Client-ID header" \
    "$(saw "$LOG_DIR/curl.log" 'Authorization: Client-ID test-key-123')"
check "the keyed run still renders a photo" \
    "$([ "$(count "$LOG_DIR/shown.log" '^CLEAR_AND_DRAW ')" = "1" ] && echo 0 || echo 1)"

# --- 7. the cache stays bounded ----------------------------------------------

echo
echo "--- cache pruning ---"
defaults
APP_DIR_T="$WORK/prune"
MAX_RUN=4
KEEP=2
run

check "a long run exits 0" \
    "$([ "$(exit_of)" = "0" ] && echo 0 || echo 1)"
check "the cache is pruned to KEEP files" \
    "$([ "$(ls -1 "$APP_DIR_T/cache" | wc -l | tr -d ' ')" -le 2 ] && echo 0 || echo 1)"
check "the photo on the panel survives the pruning" \
    "$([ -s "$(shown_files | tail -n 1)" ] && echo 0 || echo 1)"

echo
echo "checks: $((PASS + FAIL))   failed: $FAIL"
if [ "$FAIL" = "0" ]; then
    echo "PASS"
    exit 0
fi
echo "FAIL"
exit 1
