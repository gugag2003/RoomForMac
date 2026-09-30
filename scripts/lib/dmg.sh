#!/bin/bash
# Sourced by scripts/make-dmg.sh and scripts/make-dmg-layout.sh: mounting a disk
# image safely, and checking the committed Finder layout. It defines functions
# only and sets no shell options, like lib/engine-inputs.sh.
#
# The caller sets HDIUTIL (the hdiutil to run) and PYTHON3 (the python3 that
# reads .DS_Store files). RFM_DMG_RETRY_DELAY is the pause in seconds between
# retries (default 3; the bats tests set 0).
#
# Every attach uses -nobrowse -noautoopen and an explicit mount point, so no
# volume appears in Finder and nothing opens a window. Detaching is by mount
# point, which needs no parsing of hdiutil's output.

# dmg_attach MODE IMAGE MOUNTPOINT   MODE is readonly or readwrite. A read-write
# attach skips the checksum verification: it is our own temporary image.
dmg_attach() {
    local mode="$1" image="$2" mountpoint="$3" out
    mkdir -p "$mountpoint" || return 1
    case "$mode" in
        readwrite)
            out="$("$HDIUTIL" attach -nobrowse -noautoopen -readwrite -noverify \
                -mountpoint "$mountpoint" "$image" 2>&1)" || {
                printf '%s\n' "$out" >&2
                return 1
            }
            ;;
        readonly)
            out="$("$HDIUTIL" attach -nobrowse -noautoopen -readonly \
                -mountpoint "$mountpoint" "$image" 2>&1)" || {
                printf '%s\n' "$out" >&2
                return 1
            }
            ;;
        *)
            printf 'error: dmg_attach: mode must be readonly or readwrite, not %s\n' "$mode" >&2
            return 1
            ;;
    esac
}

# dmg_detach MOUNTPOINT   Retries "Resource busy" (Spotlight or a lingering
# process can hold a volume for a moment), then forces the detach as the last
# resort.
dmg_detach() {
    local mountpoint="$1" attempt=1 out=""
    while :; do
        if out="$("$HDIUTIL" detach -quiet "$mountpoint" 2>&1)"; then
            return 0
        fi
        [[ "$attempt" -lt 5 ]] || break
        attempt=$((attempt + 1))
        sleep "${RFM_DMG_RETRY_DELAY:-3}"
    done
    if out="$("$HDIUTIL" detach -quiet -force "$mountpoint" 2>&1)"; then
        return 0
    fi
    printf '%s\n' "$out" >&2
    return 1
}

# dmg_read_layout DS_STORE   Sets DMG_LAYOUT to the JSON that dsstore-layout.py
# prints for DS_STORE. The reader says why on stderr when it cannot.
dmg_read_layout() {
    local reader
    reader="$(dirname "${BASH_SOURCE[0]}")/../dsstore-layout.py"
    DMG_LAYOUT="$("$PYTHON3" "$reader" "$1")" || return 1
}

# dmg_layout_field KEY   Prints one field of DMG_LAYOUT: volume, background or
# window; or "x y" for the item named by KEY = icon:NAME, and nothing when the
# layout has no position for it.
dmg_layout_field() {
    printf '%s' "$DMG_LAYOUT" | "$PYTHON3" -c '
import json
import sys

layout = json.load(sys.stdin)
key = sys.argv[1]
if key.startswith("icon:"):
    position = layout["icons"].get(key[5:])
    print("" if position is None else "%d %d" % (position[0], position[1]))
else:
    print(layout[key])
' "$1"
}

# dmg_check_layout DS_STORE VOLUME ITEM...   Succeeds when DS_STORE was made for
# the volume VOLUME, draws /.background.tiff, and has an icon position for every
# ITEM. Finder finds the background through an alias that names the volume and
# the path, so a layout made for another name draws no background at all.
dmg_check_layout() {
    local store="$1" volume="$2" found item
    shift 2
    dmg_read_layout "$store" || return 1
    found="$(dmg_layout_field volume)" || return 1
    if [[ "$found" != "$volume" ]]; then
        printf 'error: %s was made for the volume "%s", not "%s"\n' "$store" "$found" "$volume" >&2
        return 1
    fi
    found="$(dmg_layout_field background)" || return 1
    if [[ "$found" != "/.background.tiff" ]]; then
        printf 'error: %s draws the background "%s", not "/.background.tiff"\n' "$store" "$found" >&2
        return 1
    fi
    for item in "$@"; do
        found="$(dmg_layout_field "icon:$item")" || return 1
        if [[ -z "$found" ]]; then
            printf 'error: %s has no icon position for %s\n' "$store" "$item" >&2
            return 1
        fi
    done
}
