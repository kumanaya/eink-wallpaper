#!/bin/sh
# Name: E-INK WALLPAPER
# Author: Daniel Kumanaya
# Icon: /mnt/us/documents/eink-wallpaper.jpg
# DontUseFBInk
#
# Top Unsplash photos, one per minute, full screen, until you tap.
#
# sh_integration only reads flags in the first six lines: keep Name, Author,
# Icon and DontUseFBInk up there. Icon points at the supplied Kindle cover;
# eink-wallpaper.jpg and eink-wallpaper.png are the matching cover assets.
#
# Install: copy this file and eink-wallpaper.jpg to /mnt/us/documents/.
# Optionally copy eink-wallpaper.png as a PNG sidecar. Feed, cache and log live
# in /mnt/us/documents/eink-wallpaper/.
#
# A photo every minute is a photo every minute: the feed is fetched once per
# cycle (PER_PAGE photos), each photo is rendered once at the panel size and
# then reused from the cache. With the Wi-Fi off the panel keeps turning.
#
# Feed sources, same JSON shape either way:
#   nothing set        -> the public unsplash.com feed (curated, no signup);
#   UNSPLASH_ACCESS_KEY-> https://api.unsplash.com/photos?order_by=popular
#                         (that is the real "top", and a free key unlocks it);
#   UNSPLASH_FEED_URL  -> any of the above, or your own JSON.
#
# Knobs live in $APP_DIR/unsplash.conf (see unsplash.conf.example) or in the
# environment: INTERVAL, PANEL, PER_PAGE, KEEP, MAX_RUN, ERROR_WAIT, TOUCH_DEV,
# IMAGE_PARAMS, FBINK_IMAGE_ARGS, UNSPLASH_ACCESS_KEY.

APP_DIR="${APP_DIR:-/mnt/us/documents/eink-wallpaper}"
PANEL="${PANEL:-600x800}"
INTERVAL="${INTERVAL:-60}"
PER_PAGE="${PER_PAGE:-30}"
KEEP="${KEEP:-40}"
MAX_RUN="${MAX_RUN:-0}"
ERROR_WAIT="${ERROR_WAIT:-120}"
UNSPLASH_ACCESS_KEY="${UNSPLASH_ACCESS_KEY:-}"
UNSPLASH_FEED_URL="${UNSPLASH_FEED_URL:-}"
TOUCH_DEV="${TOUCH_DEV:-}"
# imgix rendering for the panel. fbink's image decoder is stb_image, which
# handles JPEG and PNG in the same code path, so this is only a size question:
# at 600x800 the same photo is 134 KB as a q=75 JPEG and 342 KB as an 8-bit
# palette PNG. sat=-100 asks Unsplash for the grey conversion instead of
# leaving it to fbink, and con=10 spends the panel's narrow range on contrast.
IMAGE_PARAMS="${IMAGE_PARAMS:-fit=crop&crop=entropy&fm=jpg&q=75&sat=-100&con=10}"
# Passed to fbink after the file: halign/valign keep a differently sized photo
# centered on a panel that PANEL got wrong. Add ",dither" if the greys band.
FBINK_IMAGE_ARGS="${FBINK_IMAGE_ARGS:-halign=CENTER,valign=CENTER}"

CONF="${CONF:-$APP_DIR/unsplash.conf}"
[ -f "$CONF" ] && . "$CONF"

LOG="$APP_DIR/unsplash.log"
FLAG="$APP_DIR/.tapped"
CACHE="$APP_DIR/cache"
FEED="$APP_DIR/feed.json"
LIST="$APP_DIR/feed.txt"
W="${PANEL%x*}"
H="${PANEL#*x}"

# Only so the cache stays readable; fbink sniffs the format from the bytes.
EXT=png
case "$IMAGE_PARAMS" in
    *fm=jpg*|*fm=pjpg*|*fm=jpeg*) EXT=jpg ;;
esac

FBINK="${FBINK:-/mnt/us/libkh/bin/fbink}"
[ -x "$FBINK" ] || FBINK="$(command -v fbink 2>/dev/null)"

log() {
    mkdir -p "$APP_DIR" 2>/dev/null
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
}

say() {
    if [ -z "$FBINK" ]; then
        printf '%s\n' "$1"
        return
    fi
    "$FBINK" -c >/dev/null 2>&1
    printf '%s\n' "$1" | "$FBINK" -y 8 >/dev/null 2>&1
}

# Always hit the network: the CDN caches these URLs, and the same feed URL is
# fetched every cycle.
fetch() {
    url="$1"
    dest="$2"
    bust="${3:-$(date +%s)}"
    case "$url" in
        *\?*) url="${url}&t=${bust}" ;;
        *)    url="${url}?t=${bust}" ;;
    esac

    # Only the official API needs the key; the public feed ignores the header.
    AUTH=
    case "$url" in
        *api.unsplash.com*)
            [ -n "$UNSPLASH_ACCESS_KEY" ] && AUTH="Authorization: Client-ID $UNSPLASH_ACCESS_KEY"
            ;;
    esac

    if command -v curl >/dev/null 2>&1; then
        if [ -n "$AUTH" ]; then
            curl -fsSL --max-time 60 -H "$AUTH" -o "$dest" "$url"
        else
            curl -fsSL --max-time 60 -o "$dest" "$url"
        fi
        return $?
    fi
    if command -v wget >/dev/null 2>&1; then
        if [ -n "$AUTH" ]; then
            wget -q -T 60 --header="$AUTH" -O "$dest" "$url"
        else
            wget -q -T 60 -O "$dest" "$url"
        fi
        return $?
    fi
    return 127
}

feed_url() {
    if [ -n "$UNSPLASH_FEED_URL" ]; then
        printf '%s\n' "$UNSPLASH_FEED_URL"
    elif [ -n "$UNSPLASH_ACCESS_KEY" ]; then
        printf 'https://api.unsplash.com/photos?order_by=popular&per_page=%s\n' "$PER_PAGE"
    else
        printf 'https://unsplash.com/napi/photos?per_page=%s\n' "$PER_PAGE"
    fi
}

image_url() {
    printf '%s?w=%s&h=%s&%s\n' "$1" "$W" "$H" "$IMAGE_PARAMS"
}

# One cache file per photo: the photo id is already in the URL, so the panel
# never downloads the same picture twice.
image_file() {
    printf '%s/%s.%s\n' "$CACHE" "$(printf '%s\n' "$1" | sed 's|.*/||')" "$EXT"
}

load_feed() {
    mkdir -p "$APP_DIR" "$CACHE"
    fetch "$(feed_url)" "$FEED" || return 1

    # Only the photo ids matter, one URL per photo, stripped of the imgix query
    # so this script decides the size and the format. tr + grep + sed instead of
    # a JSON parser, because the Kindle does not ship one. The small_s3 variant
    # and the premium plus.unsplash.com photos fall out on the host match.
    tr '"' '\n' < "$FEED" \
        | grep -E '^https://images\.unsplash\.com/photo-[A-Za-z0-9_-]+' \
        | sed 's/[?].*$//' \
        | awk '!seen[$0]++' > "$FEED.list"

    TOTAL=$(wc -l < "$FEED.list" 2>/dev/null)
    TOTAL=$(echo "$TOTAL" | tr -d ' ')
    if [ -z "$TOTAL" ] || [ "$TOTAL" -lt 1 ]; then
        rm -f "$FEED.list"
        return 1
    fi

    # The popular list barely moves between cycles: a straight replay would show
    # the same photos in the same order. Shuffle with awk (no shuf in busybox).
    awk 'BEGIN { srand() } { print rand() "\t" $0 }' "$FEED.list" | sort -n | cut -f2- > "$LIST"
    rm -f "$FEED.list"
    return 0
}

# Download one photo into the cache. Returns 0 when the file is there.
get_photo() {
    DEST=$(image_file "$1")
    if [ ! -f "$DEST" ]; then
        if fetch "$(image_url "$1")" "$DEST.part"; then
            mv "$DEST.part" "$DEST"
        else
            rm -f "$DEST.part"
            return 1
        fi
    fi
    return 0
}

show_photo() {
    # Touch first: the mtime doubles as "last shown" for prune_cache.
    touch "$1" 2>/dev/null
    if [ -z "$FBINK" ]; then
        printf '%s\n' "$1"
        return 0
    fi
    # Clear and draw in one invocation: fbink honors -c from the image mode,
    # and two invocations would flash a white screen between them.
    "$FBINK" -c -g "file=$1,$FBINK_IMAGE_ARGS" >/dev/null 2>&1
}

# /mnt/us holds thousands of these, but the cache should not grow forever: keep
# the KEEP most recently shown photos and never remove the photo still on the
# panel while trimming.
prune_cache() {
    [ "$KEEP" -gt 0 ] 2>/dev/null || return 0
    PRESERVE="${1##*/}"
    COUNT=$(ls -1 "$CACHE" 2>/dev/null | wc -l)
    COUNT=$(echo "$COUNT" | tr -d ' ')
    [ "$COUNT" -le "$KEEP" ] && return 0
    ls -1t "$CACHE" 2>/dev/null | while IFS= read -r FILE; do
        [ "$COUNT" -le "$KEEP" ] && break
        [ "$FILE" = "$PRESERVE" ] && continue
        rm -f "$CACHE/$FILE"
        COUNT=$((COUNT - 1))
    done
}

find_touch_device() {
    D=$(awk '
        $1 == "Section" && $2 == "\"InputDevice\"" { inSec = 1; dev = ""; found = 0 }
        inSec && $2 == "\"Device\"" { dev = $3 }
        inSec && $2 == "\"CorePointer\"" && dev != "" { found = 1 }
        inSec && $1 == "EndSection" {
            if (found && dev != "") { gsub(/"/, "", dev); print dev; exit }
            inSec = 0; dev = ""; found = 0
        }
    ' /etc/xorg.conf 2>/dev/null)
    [ -n "$D" ] && [ -e "$D" ] && { echo "$D"; return; }

    D=$(awk '
        /^N: Name=/ {
            name = $0
            sub(/^N: Name="/, "", name)
            sub(/"$/, "", name)
            ev = ""
        }
        /^H: Handlers=/ {
            for (i = 1; i <= NF; i++) {
                t = $i
                sub(/^Handlers=/, "", t)
                if (t ~ /^event[0-9]+$/) ev = t
            }
        }
        /^B: ABS=/ {
            if (ev != "") {
                if (tolower(name) ~ /(touch|zforce|cyttsp|elan|goodix|ft5|atmel|synaptics|eink|st1232)/) {
                    if (best == "") best = ev
                }
                if (fallback == "") fallback = ev
            }
        }
        END {
            if (best != "") print "/dev/input/" best
            else if (fallback != "") print "/dev/input/" fallback
        }
    ' /proc/bus/input/devices 2>/dev/null)
    [ -n "$D" ] && [ -e "$D" ] && { echo "$D"; return; }

    for D in /dev/input/event1 /dev/input/event0 /dev/input/event2; do
        [ -e "$D" ] && { echo "$D"; return; }
    done
}

# Returns 0 when the interval is up (next photo), 1 on a tap (leave).
wait_next() {
    hold="$1"
    DEV="$TOUCH_DEV"
    [ -z "$DEV" ] && DEV=$(find_touch_device)
    rm -f "$FLAG"
    if [ -n "$DEV" ] && [ -e "$DEV" ]; then
        dd if="$DEV" bs=16 count=1 >/dev/null 2>&1 && touch "$FLAG" &
        JOB=$!
    else
        JOB=""
    fi
    # WAITED, not N: this function shares the script's global scope with the
    # main loop, and reusing its counters is how eink-news capped the board at
    # `hold` slides.
    WAITED=0
    while [ ! -f "$FLAG" ]; do
        sleep 1
        WAITED=$((WAITED + 1))
        if [ "$WAITED" -ge "$hold" ]; then
            [ -n "$JOB" ] && kill "$JOB" 2>/dev/null
            wait "$JOB" 2>/dev/null
            rm -f "$FLAG"
            return 0
        fi
    done
    [ -n "$JOB" ] && kill "$JOB" 2>/dev/null
    wait "$JOB" 2>/dev/null
    rm -f "$FLAG"
    return 1
}

leave() {
    lipc-set-prop com.lab126.powerd preventScreenSaver 0 >/dev/null 2>&1
    [ -n "$FBINK" ] && "$FBINK" -c >/dev/null 2>&1
    lipc-set-prop com.lab126.appmgrd start app://com.lab126.booklet.home >/dev/null 2>&1
}

rm -f "$FLAG"
mkdir -p "$APP_DIR" "$CACHE"

if [ -n "$UNSPLASH_ACCESS_KEY" ]; then
    log "start panel=$PANEL interval=${INTERVAL}s per_page=$PER_PAGE feed=api"
else
    log "start panel=$PANEL interval=${INTERVAL}s per_page=$PER_PAGE feed=public"
fi

say "UNSPLASH
loading top photos..."

lipc-set-prop com.lab126.powerd preventScreenSaver 1 >/dev/null 2>&1

SHOWN=0
while true; do
    if ! load_feed; then
        if [ ! -s "$LIST" ]; then
            say "Could not reach Unsplash.

Need curl or wget with HTTPS.
Tap to go back."
            log "feed fetch failed and there is no cached list"
            wait_next "$ERROR_WAIT"
            leave
            exit 1
        fi
        log "feed fetch failed, reusing the cached list"
    fi

    TOTAL=$(wc -l < "$LIST" 2>/dev/null)
    TOTAL=$(echo "$TOTAL" | tr -d ' ')
    if [ -z "$TOTAL" ] || [ "$TOTAL" -lt 1 ]; then
        say "Unsplash returned no photos.
Tap to go back."
        log "feed parsed to zero photos"
        wait_next "$ERROR_WAIT"
        leave
        exit 1
    fi
    log "cycle of $TOTAL photos"

    CYCLE=0
    I=1
    while [ "$I" -le "$TOTAL" ]; do
        LINE=$(sed -n "${I}p" "$LIST")
        DEST=$(image_file "$LINE")
        if get_photo "$LINE"; then
            show_photo "$DEST"
            CURRENT="$DEST"
            SHOWN=$((SHOWN + 1))
            CYCLE=$((CYCLE + 1))
            # Prefetch the next photo while this one is on the panel.
            NEXT=$((I + 1))
            [ "$NEXT" -gt "$TOTAL" ] && NEXT=1
            NEXT_LINE=$(sed -n "${NEXT}p" "$LIST")
            get_photo "$NEXT_LINE" || log "prefetch failed: $NEXT_LINE"
            prune_cache "$CURRENT"

            if [ "$MAX_RUN" -gt 0 ] 2>/dev/null && [ "$SHOWN" -ge "$MAX_RUN" ]; then
                log "run limit $MAX_RUN reached, $SHOWN photos"
                leave
                exit 0
            fi
        else
            log "download failed: $LINE"
        fi

        if ! wait_next "$INTERVAL"; then
            log "tap, leaving after $SHOWN photos"
            leave
            exit 0
        fi

        I=$((I + 1))
    done

    if [ "$CYCLE" -eq 0 ]; then
        log "a whole cycle showed nothing, holding the screen"
        sleep 5
    fi
done
