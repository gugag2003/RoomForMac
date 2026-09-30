#!/usr/bin/env bash
# Loaded by make_dmg.bats (`load dmg_stubs`). It is a helper of that file only.
#
# Stand-ins for hdiutil, diskutil and codesign, so the disk-image tests never
# create, attach or mount a real image (a real attach can open a Finder window,
# and a real hdiutil is deprecated and slow). A fake image is a small text file
# that names a folder, its "store", under $STATE/stores. `attach` turns the mount
# point into a link to that folder and `detach` puts an empty folder back, so the
# script under test sees a volume it can read, write and check with the real xattr,
# cmp and readlink. Every call is appended to $STATE/calls.log, and the stubs
# refuse any attach that lacks -nobrowse, -noautoopen or -mountpoint, the flags
# that keep a real attach from opening a window.
#
# The stubs fail on request, through environment variables that a test sets for
# one run:
#   STUB_CREATE_BUSY=N     the first N `hdiutil create` calls answer "Resource busy"
#   STUB_DETACH_BUSY=N     the first N plain `hdiutil detach` calls answer "Resource busy"
#   STUB_DISKUTIL_FAIL=1   `diskutil image create from` fails (so hdiutil convert runs)
#   STUB_CONVERT_FAIL=1    `hdiutil convert` fails too
#   STUB_FORCE_FS=NAME     the created image records this file system, whatever -fs said
#   STUB_DROP=NAME         the compressed image lacks this root entry
#   STUB_ALTER=NAME        the compressed image holds a changed copy of this root file
#   STUB_APPLICATIONS_DIR=1  the compressed image has a folder where the Applications link belongs
#   STUB_APPLICATIONS_LINK=PATH  the compressed image's Applications link points at PATH
#   STUB_NO_ICON_FLAG=1    the compressed image lost the volume's Finder info
#   STUB_CODESIGN_FAIL=1   `codesign --verify` fails for anything inside a check mount
#
# The codesign stub otherwise runs the real /usr/bin/codesign, on purpose: the
# copy of the fake app that reaches the fake volume is verified for real.

# write_dmg_stubs DIR   Writes the stubs into DIR and puts DIR first on PATH.
# Sets and exports HDIUTIL, DISKUTIL, CODESIGN and PATH; the caller sets STATE.
write_dmg_stubs() {
    local dir="$1"
    mkdir -p "$dir" "$STATE"

    cat > "$dir/stub-lib.bash" << 'STUB'
# Shared by the hdiutil and diskutil stubs.
image_field() { # FILE KEY
    sed -n "s/^$2=//p" "$1" | head -n 1
}
new_store() {
    local n
    n=$(($(cat "$STATE/stores.count" 2> /dev/null || echo 0) + 1))
    echo "$n" > "$STATE/stores.count"
    mkdir -p "$STATE/stores/$n"
    printf '%s\n' "$STATE/stores/$n"
}
copy_store() { # SRC DST: ditto, plus the root folder's Finder info, which ditto drops
    local hex
    ditto "$1" "$2"
    hex="$(xattr -px com.apple.FinderInfo "$1" 2> /dev/null | tr -d ' \n')" || hex=""
    if [[ -n "$hex" ]]; then
        xattr -wx com.apple.FinderInfo "$hex" "$2"
    fi
}
write_image() { # PATH STORE VOLNAME FS FORMAT
    printf 'FAKE-DMG\nstore=%s\nvolname=%s\nfs=%s\nformat=%s\n' "$2" "$3" "$4" "$5" > "$1"
}
convert_image() { # SRC OUT FORMAT: what compressing does to the image
    local store source
    [[ -f "$1" && "$(head -n 1 "$1")" == FAKE-DMG ]] || {
        echo "stub: $1 is not an image" >&2
        return 1
    }
    source="$(image_field "$1" store)"
    store="$(new_store)"
    copy_store "$source" "$store"
    if [[ -n "${STUB_DROP:-}" ]]; then
        rm -rf "${store:?}/$STUB_DROP"
    fi
    if [[ -n "${STUB_ALTER:-}" ]]; then
        printf 'changed' >> "$store/$STUB_ALTER"
    fi
    if [[ -n "${STUB_APPLICATIONS_LINK:-}" ]]; then
        rm -f "$store/Applications"
        ln -s "$STUB_APPLICATIONS_LINK" "$store/Applications"
    fi
    if [[ "${STUB_APPLICATIONS_DIR:-0}" == 1 ]]; then
        rm -f "$store/Applications"
        mkdir "$store/Applications"
    fi
    if [[ "${STUB_NO_ICON_FLAG:-0}" == 1 ]]; then
        xattr -d com.apple.FinderInfo "$store" 2> /dev/null || true
    fi
    write_image "$2" "$store" "$(image_field "$1" volname)" "$(image_field "$1" fs)" "$3"
}
STUB

    cat > "$dir/hdiutil" << 'STUB'
#!/bin/bash
# hdiutil(1) stand-in: see scripts/tests/dmg_stubs.bash.
set -euo pipefail
: "${STATE:?}"
. "$(dirname "$0")/stub-lib.bash"
printf 'hdiutil %s\n' "$*" >> "$STATE/calls.log"
unexpected() {
    echo "stub hdiutil: unexpected argument: $1" >&2
    exit 64
}
verb="${1:-}"
shift || true
case "$verb" in
    create)
        volname="" fs="" source="" format="" out=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -volname) volname="$2"; shift 2 ;;
                -fs) fs="$2"; shift 2 ;;
                -srcfolder) source="$2"; shift 2 ;;
                -format) format="$2"; shift 2 ;;
                -quiet | -ov) shift ;;
                -*) unexpected "$1" ;;
                *) out="$1"; shift ;;
            esac
        done
        count=$(($(cat "$STATE/creates" 2> /dev/null || echo 0) + 1))
        echo "$count" > "$STATE/creates"
        if [[ "$count" -le "${STUB_CREATE_BUSY:-0}" ]]; then
            echo "hdiutil: create failed - Resource busy" >&2
            exit 16
        fi
        [[ -d "$source" && -n "$out" ]] || {
            echo "hdiutil: create failed - No such file or directory" >&2
            exit 1
        }
        store="$(new_store)"
        ditto "$source" "$store"
        write_image "$out" "$store" "$volname" "${STUB_FORCE_FS:-$fs}" "$format"
        ;;
    convert)
        format="" out="" source=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -format) format="$2"; shift 2 ;;
                -o) out="$2"; shift 2 ;;
                -quiet) shift ;;
                -*) unexpected "$1" ;;
                *) source="$1"; shift ;;
            esac
        done
        if [[ "${STUB_CONVERT_FAIL:-0}" == 1 ]]; then
            echo "hdiutil: convert failed - Operation not permitted" >&2
            exit 1
        fi
        convert_image "$source" "$out" "$format"
        ;;
    attach)
        mode="" mount="" image="" nobrowse=0 noautoopen=0
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -nobrowse) nobrowse=1; shift ;;
                -noautoopen) noautoopen=1; shift ;;
                -readonly | -readwrite) mode="${1#-}"; shift ;;
                -noverify | -quiet) shift ;;
                -mountpoint) mount="$2"; shift 2 ;;
                -*) unexpected "$1" ;;
                *) image="$1"; shift ;;
            esac
        done
        if [[ "$nobrowse" -ne 1 || "$noautoopen" -ne 1 || -z "$mount" || -z "$mode" ]]; then
            echo "stub hdiutil: attach needs -nobrowse -noautoopen -mountpoint and -readonly or -readwrite" >&2
            exit 64
        fi
        [[ -f "$image" && "$(head -n 1 "$image")" == FAKE-DMG ]] || {
            echo "hdiutil: attach failed - not recognized" >&2
            exit 1
        }
        mkdir -p "$mount"
        rmdir "$mount"
        ln -s "$(image_field "$image" store)" "$mount"
        printf '%s|%s|%s|%s\n' "$mount" "$(image_field "$image" store)" "$mode" "$image" >> "$STATE/attached"
        printf '/dev/disk9\tGUID_partition_scheme\t\n/dev/disk9s1\tApple_HFS\t%s\n' "$mount"
        ;;
    detach)
        force=0 target=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -quiet) shift ;;
                -force) force=1; shift ;;
                -*) unexpected "$1" ;;
                *) target="$1"; shift ;;
            esac
        done
        if [[ "$force" -eq 0 ]]; then
            count=$(($(cat "$STATE/detaches" 2> /dev/null || echo 0) + 1))
            echo "$count" > "$STATE/detaches"
            if [[ "$count" -le "${STUB_DETACH_BUSY:-0}" ]]; then
                echo "hdiutil: couldn't unmount \"$target\" - Resource busy" >&2
                exit 16
            fi
        fi
        if ! grep -q "^$target|" "$STATE/attached" 2> /dev/null; then
            echo "hdiutil: detach failed - No such file or directory" >&2
            exit 1
        fi
        grep -v "^$target|" "$STATE/attached" > "$STATE/attached.new" || true
        mv "$STATE/attached.new" "$STATE/attached"
        rm "$target"
        mkdir "$target"
        ;;
    info)
        echo "framework       : 999 (stub)"
        echo "================================================"
        if [[ -s "$STATE/attached" ]]; then
            while IFS='|' read -r mount _ mode image; do
                printf 'image-path      : %s\nmount-point     : %s (%s)\n' "$image" "$mount" "$mode"
            done < "$STATE/attached"
        fi
        ;;
    *)
        echo "stub hdiutil: unexpected verb: $verb" >&2
        exit 64
        ;;
esac
STUB

    cat > "$dir/diskutil" << 'STUB'
#!/bin/bash
# diskutil(1) stand-in: see scripts/tests/dmg_stubs.bash.
set -euo pipefail
: "${STATE:?}"
. "$(dirname "$0")/stub-lib.bash"
printf 'diskutil %s\n' "$*" >> "$STATE/calls.log"
if [[ "${1:-}" == image && "${2:-}" == create && "${3:-}" == from ]]; then
    shift 3
    if [[ "${1:-}" != --format || $# -ne 4 ]]; then
        echo "stub diskutil: expected: image create from --format FORMAT SOURCE DESTINATION" >&2
        exit 64
    fi
    if [[ "${STUB_DISKUTIL_FAIL:-0}" == 1 ]]; then
        echo "diskutil: image create from failed: unrecognized verb" >&2
        exit 1
    fi
    convert_image "$3" "$4" "$2"
elif [[ "${1:-}" == info && $# -eq 2 ]]; then
    image="$(awk -F'|' -v m="$2" '$1 == m { print $4 }' "$STATE/attached" 2> /dev/null | head -n 1)"
    [[ -n "$image" ]] || {
        echo "Could not find disk: $2" >&2
        exit 1
    }
    fs="$(image_field "$image" fs)"
    printf '   Device Identifier:         disk9s1\n   Mounted:                   Yes\n   Mount Point:               %s\n' "$2"
    printf '   File System Personality:   %s\n' "$fs"
else
    echo "stub diskutil: unexpected arguments: $*" >&2
    exit 64
fi
STUB

    cat > "$dir/codesign" << 'STUB'
#!/bin/bash
# codesign(1) stand-in: logs the call, fails a verify inside a check mount when
# asked, and otherwise runs the real codesign.
set -euo pipefail
: "${STATE:?}"
printf 'codesign %s\n' "$*" >> "$STATE/calls.log"
if [[ "${STUB_CODESIGN_FAIL:-0}" == 1 && "$*" == *mount-check* ]]; then
    echo "${*: -1}: a sealed resource is missing or invalid" >&2
    exit 1
fi
exec /usr/bin/codesign "$@"
STUB

    chmod +x "$dir/hdiutil" "$dir/diskutil" "$dir/codesign"
    HDIUTIL="$dir/hdiutil"
    DISKUTIL="$dir/diskutil"
    CODESIGN="$dir/codesign"
    PATH="$dir:$PATH"
    export HDIUTIL DISKUTIL CODESIGN PATH STATE
}

# image_store IMAGE: the folder a fake image stands for.
image_store() {
    sed -n 's/^store=//p' "$1" | head -n 1
}

# image_field IMAGE KEY: volname, fs or format of a fake image.
image_field() {
    sed -n "s/^$2=//p" "$1" | head -n 1
}

# attached_count: how many fake images are attached right now.
attached_count() {
    if [[ -s "$STATE/attached" ]]; then
        wc -l < "$STATE/attached" | tr -d ' '
    else
        echo 0
    fi
}

# calls_to WORDS: how many logged calls start with WORDS (for example "hdiutil create").
calls_to() {
    if [[ -f "$STATE/calls.log" ]]; then
        grep -c "^$1" "$STATE/calls.log" || true
    else
        echo 0
    fi
}

# write_dmgbuild_stubs DIR   For make-dmg-layout.sh: writes a python3 wrapper into
# DIR (not onto PATH) and sets PYTHON3 to it. `python3 -m venv V` makes a fake venv;
# its python answers `-m pip install` (and insists on --require-hashes and -r); its
# dmgbuild runs the real settings file to learn the icon positions and the window,
# and makes a fake image whose root holds the .DS_Store dmgbuild would have written,
# built with dsstore_fixture.py. Anything else runs the real python3.
#   STUB_PIP_FAIL=1          pip fails
#   STUB_DMGBUILD_FAIL=1     dmgbuild fails
#   STUB_LAYOUT_VOLUME=NAME  the volume name the fake layout is made for
# Needs write_dmg_stubs first: the fake dmgbuild builds its image through $HDIUTIL.
write_dmgbuild_stubs() {
    local dir="$1"
    mkdir -p "$dir"
    REAL_PYTHON3="$(command -v python3)"
    FIXTURE_DIR="$BATS_TEST_DIRNAME"

    cat > "$dir/python3" << 'STUB'
#!/bin/bash
# python3 stand-in: makes fake venvs, runs the real python3 for everything else.
set -euo pipefail
: "${STATE:?}" "${REAL_PYTHON3:?}"
if [[ "${1:-}" == -m && "${2:-}" == venv ]]; then
    printf 'python3 -m venv %s\n' "$3" >> "$STATE/calls.log"
    mkdir -p "$3/bin"
    cp "$(dirname "$0")/venv-python" "$3/bin/python"
    cp "$(dirname "$0")/venv-dmgbuild" "$3/bin/dmgbuild"
    chmod +x "$3/bin/python" "$3/bin/dmgbuild"
    exit 0
fi
exec "$REAL_PYTHON3" "$@"
STUB

    cat > "$dir/venv-python" << 'STUB'
#!/bin/bash
# The python of a fake venv: pip is a stub, the rest is the real python3.
set -euo pipefail
: "${STATE:?}" "${REAL_PYTHON3:?}"
if [[ "${1:-}" == -m && "${2:-}" == pip ]]; then
    printf 'pip %s\n' "$*" >> "$STATE/calls.log"
    if [[ "$*" != *" --require-hashes "* || "$*" != *" -r "* ]]; then
        echo "stub pip: needs --require-hashes -r FILE" >&2
        exit 2
    fi
    if [[ "${STUB_PIP_FAIL:-0}" == 1 ]]; then
        echo "ERROR: Could not find a version that satisfies the requirement dmgbuild==1.6.7" >&2
        exit 1
    fi
    exit 0
fi
exec "$REAL_PYTHON3" "$@"
STUB

    cat > "$dir/venv-dmgbuild" << 'STUB'
#!/bin/bash
# dmgbuild stand-in: dmgbuild -s SETTINGS [-D key=value]... VOLUME OUTPUT
set -euo pipefail
: "${STATE:?}" "${REAL_PYTHON3:?}" "${FIXTURE_DIR:?}" "${HDIUTIL:?}"
printf 'dmgbuild %s\n' "$*" >> "$STATE/calls.log"
settings="" volume="" out="" defines="$STATE/dmgbuild.defines"
: > "$defines"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -s) settings="$2"; shift 2 ;;
        -D) printf '%s\n' "$2" >> "$defines"; shift 2 ;;
        *)
            if [[ -z "$volume" ]]; then volume="$1"; else out="$1"; fi
            shift
            ;;
    esac
done
if [[ "${STUB_DMGBUILD_FAIL:-0}" == 1 ]]; then
    echo "dmgbuild: error: the disk image could not be created" >&2
    exit 1
fi
stage="$STATE/dmgbuild-stage"
rm -rf "$stage"
mkdir -p "$stage"
"$REAL_PYTHON3" - "$settings" "$defines" "${STUB_LAYOUT_VOLUME:-$volume}" "$stage/.DS_Store" << 'PY'
import os
import sys

settings, defines_file, volume, target = sys.argv[1:5]
defines = {}
for line in open(defines_file):
    key, _, value = line.rstrip("\n").partition("=")
    defines[key] = value
namespace = {"defines": defines}
exec(compile(open(settings).read(), settings, "exec"), namespace)
(left, top), (width, height) = namespace["window_rect"]
sys.path.insert(0, os.environ["FIXTURE_DIR"])
import dsstore_fixture

options = {
    "volume": volume,
    "background": "/.background.tiff",
    "icons": [(name, x, y) for name, (x, y) in namespace["icon_locations"].items()],
    "alias": True,
    "window": "{{%d, %d}, {%d, %d}}" % (left, top, width, height),
    "tree": False,
}
with open(target, "wb") as handle:
    handle.write(dsstore_fixture.build_file(options))
PY
"$HDIUTIL" create -quiet -ov -volname "$volume" -fs HFS+ -srcfolder "$stage" -format UDZO "$out"
STUB

    chmod +x "$dir/python3"
    PYTHON3="$dir/python3"
    export PYTHON3 REAL_PYTHON3 FIXTURE_DIR
}
