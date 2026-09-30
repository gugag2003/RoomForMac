#!/bin/bash
# Build RoomForMac.dmg from a signed RoomForMac.app, headless: no Finder, no
# AppleScript and no third-party tool. The window layout (icon positions, the
# background picture, the hidden toolbar) is the committed packaging/dmg/DS_Store,
# made once by scripts/make-dmg-layout.sh; this script only copies it in.
#
# The image is HFS+, because a folder-made APFS image loses its .DS_Store and
# `hdiutil makehybrid` gives every file Finder info that strict codesign refuses.
# It is compressed with `diskutil image create from` (hdiutil is deprecated on
# macOS 27), falling back to `hdiutil convert`, and then mounted read-only and
# checked, so a release never ships an image that is missing something.
#
# Progress goes to stderr. Stdout is one line: "<out.dmg> <bytes> <sha256>".

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/distribution.sh
. "$ROOT/scripts/lib/distribution.sh"
# shellcheck source=lib/dmg.sh
. "$ROOT/scripts/lib/dmg.sh"

FORMAT="${FORMAT:-ULMO}"
PACKAGING="${PACKAGING:-$ROOT/packaging/dmg}"
# The volume icon is packaging/icon/VolumeIcon.icns, which scripts/export-app-icon.swift
# writes. VOLUME_ICON is for tests.
VOLUME_ICON="${VOLUME_ICON:-$ROOT/packaging/icon/VolumeIcon.icns}"
# Every tool that mounts an image, compresses one, signs or reads the layout is
# called through one of these variables, so the bats tests can put stubs there.
HDIUTIL="${HDIUTIL:-/usr/bin/hdiutil}"
DISKUTIL="${DISKUTIL:-/usr/sbin/diskutil}"
CODESIGN="${CODESIGN:-/usr/bin/codesign}"
PYTHON3="${PYTHON3:-python3}"

# Finder info of the volume's root folder with kHasCustomIcon (0x0400) set: it
# makes Finder show .VolumeIcon.icns. This is what `SetFile -a C` writes.
FINDER_INFO="0000000000000000040000000000000000000000000000000000000000000000"

usage() {
    cat << 'EOF'
Usage: scripts/make-dmg.sh <RoomForMac.app> <out.dmg>

Builds the disk image: RoomForMac.app, a link to /Applications, the window
background, the committed Finder layout and the volume icon. It mounts the
finished image read-only and checks it before it writes <out.dmg>.

Environment:
  FORMAT     ULMO (default, smallest), ULFO or UDZO
  PACKAGING  the folder holding DS_Store and background.tiff (default packaging/dmg)
  HDIUTIL, DISKUTIL, CODESIGN, PYTHON3   tools (defaults: the system ones)

Prints "<out.dmg> <bytes> <sha256>" on stdout.
Exit status: 0 done; 1 a step or a check failed; 2 usage error.
EOF
}

usage_error() {
    printf 'error: %s\n' "$*" >&2
    printf 'Run scripts/make-dmg.sh --help for usage.\n' >&2
    exit 2
}
die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}
say() { printf '==> %s\n' "$*" >&2; }

case "${1:-}" in
    -h | --help)
        usage
        exit 0
        ;;
esac
[[ $# -eq 2 ]] || usage_error "expected <RoomForMac.app> <out.dmg>"
case "$FORMAT" in
    ULMO | ULFO | UDZO) ;;
    *) usage_error "FORMAT must be ULMO, ULFO or UDZO, not $FORMAT" ;;
esac
APP="${1%/}"
OUT="$2"
APP_NAME="$(basename "$APP")"
[[ "$APP_NAME" == *.app && -d "$APP" ]] || usage_error "$APP is not an app bundle"
[[ ! -d "$OUT" ]] || usage_error "$OUT is a folder"

if [[ -n "${RFM_DMG_VOLUME_NAME_OVERRIDE:-}" ]]; then
    VOLUME_NAME="$RFM_DMG_VOLUME_NAME_OVERRIDE" # tests only
else
    VOLUME_NAME="$(distribution_value "$ROOT" RFM_DMG_VOLUME_NAME)" || exit 1
fi

# 1. The layout: the volume name, the background and the icon positions.
say "checking the window layout"
for input in "$PACKAGING/DS_Store" "$PACKAGING/background.tiff" "$VOLUME_ICON"; do
    [[ -f "$input" ]] || die "$input does not exist"
done
dmg_check_layout "$PACKAGING/DS_Store" "$VOLUME_NAME" "$APP_NAME" Applications || exit 1

TEMP_ROOT="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "${TEMP_ROOT%/}/rfm-dmg.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
RW_MOUNT=""
CHECK_MOUNT=""

# Detaches whatever is still attached, then removes the temporary folder. It
# never removes the folder while a volume might still be mounted inside it.
cleanup() {
    local status=$? mount keep=0
    trap - EXIT
    for mount in "$RW_MOUNT" "$CHECK_MOUNT"; do
        if [[ -n "$mount" ]] && ! "$HDIUTIL" detach -quiet -force "$mount" > /dev/null 2>&1; then
            printf 'warning: could not detach %s; leaving %s in place\n' "$mount" "$WORK" >&2
            keep=1
        fi
    done
    if [[ "$keep" -eq 0 ]]; then
        rm -rf "$WORK"
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 1' INT TERM HUP

# 2. Only a sound app goes in.
say "checking $APP_NAME"
if ! VERIFY_LOG="$("$CODESIGN" --verify --deep --strict "$APP" 2>&1)"; then
    printf '%s\n' "$VERIFY_LOG" >&2
    die "$APP_NAME does not pass codesign --verify --deep --strict"
fi

# 3. The image root, staged with ditto so links and signatures survive.
say "staging the image root"
STAGE="$WORK/stage"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP_NAME"
ln -s /Applications "$STAGE/Applications"
cp "$PACKAGING/background.tiff" "$STAGE/.background.tiff"
cp "$PACKAGING/DS_Store" "$STAGE/.DS_Store"
cp "$VOLUME_ICON" "$STAGE/.VolumeIcon.icns"

# 4. A read-write HFS+ image. hdiutil sometimes answers "Resource busy" on
# hosted runners, so this retries a few times.
RW_IMAGE="$WORK/rw.dmg"
create_read_write_image() {
    local attempt=1 out
    while :; do
        if out="$("$HDIUTIL" create -quiet -ov -volname "$VOLUME_NAME" -fs HFS+ \
            -srcfolder "$STAGE" -format UDRW "$RW_IMAGE" 2>&1)"; then
            return 0
        fi
        if [[ "$out" != *"Resource busy"* || "$attempt" -ge 5 ]]; then
            printf '%s\n' "$out" >&2
            return 1
        fi
        say "hdiutil create said \"Resource busy\"; trying again ($attempt of 5)"
        attempt=$((attempt + 1))
        rm -f "$RW_IMAGE"
        sleep "${RFM_DMG_RETRY_DELAY:-3}"
    done
}
say "creating the read-write image"
create_read_write_image || die "hdiutil could not create the image"

# 5. The custom-icon flag on the volume's root folder.
say "setting the volume icon flag"
RW_MOUNT="$WORK/mount-rw"
dmg_attach readwrite "$RW_IMAGE" "$RW_MOUNT" || die "could not attach the read-write image"
xattr -wx com.apple.FinderInfo "$FINDER_INFO" "$RW_MOUNT" || die "could not set the volume icon flag"
dmg_detach "$RW_MOUNT" || die "could not detach the read-write image"
RW_MOUNT=""

# 6. Compress.
say "compressing to $FORMAT"
FINAL_IMAGE="$WORK/RoomForMac.dmg"
if ! "$DISKUTIL" image create from --format "$FORMAT" "$RW_IMAGE" "$FINAL_IMAGE" > "$WORK/compress.log" 2>&1; then
    say "diskutil could not compress it ($(head -n 1 "$WORK/compress.log")); trying hdiutil convert"
    rm -f "$FINAL_IMAGE"
    if ! "$HDIUTIL" convert -quiet "$RW_IMAGE" -format "$FORMAT" -o "$FINAL_IMAGE" > "$WORK/compress.log" 2>&1; then
        cat "$WORK/compress.log" >&2
        die "could not compress the image"
    fi
fi
[[ -f "$FINAL_IMAGE" ]] || die "the compressor wrote no image"

# 7. Mount the result read-only and check it.
say "checking the finished image"
CHECK_MOUNT="$WORK/mount-check"
dmg_attach readonly "$FINAL_IMAGE" "$CHECK_MOUNT" || die "could not attach the finished image"

[[ -d "$CHECK_MOUNT/$APP_NAME" ]] || die "the image has no $APP_NAME"
if [[ ! -L "$CHECK_MOUNT/Applications" || "$(readlink "$CHECK_MOUNT/Applications")" != /Applications ]]; then
    die "Applications in the image is not a link to /Applications"
fi
# has_custom_icon_flag DIR: kHasCustomIcon (0x0400) is set in the Finder flags,
# the two bytes at offset 8 of DIR's 32-byte com.apple.FinderInfo.
has_custom_icon_flag() {
    local hex
    hex="$(xattr -px com.apple.FinderInfo "$1" 2> /dev/null | tr -d ' \n')" || return 1
    [[ "${#hex}" -eq 64 ]] || return 1
    (((0x${hex:16:4} & 0x0400) != 0))
}
check_copy() { # NAME SOURCE: the image's hidden file is a byte-for-byte copy
    [[ -f "$CHECK_MOUNT/$1" ]] || die "the image has no $1"
    cmp -s "$CHECK_MOUNT/$1" "$2" || die "$1 in the image differs from $2"
}
check_copy .DS_Store "$PACKAGING/DS_Store"
check_copy .background.tiff "$PACKAGING/background.tiff"
check_copy .VolumeIcon.icns "$VOLUME_ICON"

has_custom_icon_flag "$CHECK_MOUNT" || die "the image's volume does not carry the custom-icon flag"
DISK_INFO="$("$DISKUTIL" info "$CHECK_MOUNT" 2>&1)" || die "diskutil info failed: $DISK_INFO"
[[ "$DISK_INFO" == *"HFS+"* ]] || die "the image is not HFS+"
if ! VERIFY_LOG="$("$CODESIGN" --verify --deep --strict "$CHECK_MOUNT/$APP_NAME" 2>&1)"; then
    printf '%s\n' "$VERIFY_LOG" >&2
    die "$APP_NAME inside the image does not pass codesign --verify --deep --strict"
fi

dmg_detach "$CHECK_MOUNT" || die "could not detach the finished image"
CHECK_MOUNT=""

# 8. Publish the result only now, so a failed run leaves no partial image.
mkdir -p "$(dirname "$OUT")"
mv -f "$FINAL_IMAGE" "$OUT"
BYTES="$(wc -c < "$OUT" | tr -d ' ')"
SHA256="$(shasum -a 256 "$OUT" | cut -d' ' -f1)"
printf '%s %s %s\n' "$OUT" "$BYTES" "$SHA256"
