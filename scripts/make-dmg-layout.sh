#!/bin/bash
# Make packaging/dmg/DS_Store, the Finder window layout of the disk image, once.
# It builds a throwaway image with dmgbuild (in a git-ignored venv), copies the
# .DS_Store that dmgbuild wrote out of it, checks it with dsstore-layout.py, and
# only then replaces the committed file. Run it by hand when the background or the
# icon positions change; never in CI. scripts/make-dmg.sh does not need dmgbuild
# or Python packages: it copies the committed file into every release image.
#
# The one command that needs the network is pip, which installs the three pinned
# packages with their hashes (packaging/dmg/dmgbuild-requirements.txt).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/distribution.sh
. "$ROOT/scripts/lib/distribution.sh"
# shellcheck source=lib/dmg.sh
. "$ROOT/scripts/lib/dmg.sh"

HDIUTIL="${HDIUTIL:-/usr/bin/hdiutil}"
PYTHON3="${PYTHON3:-python3}"
# Internal: where the venv lives and where volumes mount (the bats tests move
# both), and RFM_DMG_KEEP_WORK=1, which keeps the temporary folder so a layout the
# reader refuses can be looked at.
VENV="${DMGBUILD_VENV:-$ROOT/build/dmgbuild-venv}"
VOLUMES_DIR="${VOLUMES_DIR:-/Volumes}"
PACKAGING="$ROOT/packaging/dmg"

# The positions the settings file gives the two icons, which the background's
# arrow is drawn between (scripts/make-dmg-background.swift).
APP_POSITION="165 120"
APPLICATIONS_POSITION="495 120"

usage() {
    cat << 'EOF'
Usage: scripts/make-dmg-layout.sh [--app <RoomForMac.app>] [--help]

Makes packaging/dmg/DS_Store with dmgbuild 1.6.7, in build/dmgbuild-venv, and
checks it. Needs the network once, for pip, and Python 3.10 or later
(set PYTHON3 to choose one). Eject any mounted "RoomForMac" volume first.

  --app PATH   put this app in the throwaway image (default: an empty
               RoomForMac.app folder: only its name matters to the layout)

Exit status: 0 done; 1 a step or a check failed; 2 usage error or refusal.
EOF
}

usage_error() {
    printf 'error: %s\n' "$*" >&2
    printf 'Run scripts/make-dmg-layout.sh --help for usage.\n' >&2
    exit 2
}
die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}
say() { printf '==> %s\n' "$*" >&2; }

APP_NAME="RoomForMac.app"
APP=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)
            [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || usage_error "--app needs a value"
            APP="${2%/}"
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) usage_error "unknown argument: $1" ;;
    esac
done

[[ -z "${CI:-}" ]] || usage_error "this is a one-time authoring tool and never runs in CI"
[[ -z "$APP" || -d "$APP" ]] || usage_error "$APP is not a folder"
[[ -z "$APP" || "$(basename "$APP")" == "$APP_NAME" ]] || usage_error "--app must be named $APP_NAME: the layout is keyed on the item's name"
"$PYTHON3" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' ||
    usage_error "dmgbuild needs Python 3.10 or later; set PYTHON3 to one (for example /opt/homebrew/bin/python3)"

VOLUME_NAME="$(distribution_value "$ROOT" RFM_DMG_VOLUME_NAME)" || exit 1
for input in dmgbuild-settings.py dmgbuild-requirements.txt background.png background@2x.png; do
    [[ -f "$PACKAGING/$input" ]] || die "$PACKAGING/$input does not exist"
done
# dmgbuild bakes the name of the volume it mounts into the layout. If a volume
# with this name is already mounted, the throwaway one mounts as "RoomForMac 1".
[[ ! -e "$VOLUMES_DIR/$VOLUME_NAME" ]] || usage_error "a volume named $VOLUME_NAME is mounted; eject it first"

TEMP_ROOT="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "${TEMP_ROOT%/}/rfm-dmg-layout.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
MOUNT=""
cleanup() {
    local status=$? keep=0
    trap - EXIT
    if [[ -n "$MOUNT" ]] && ! "$HDIUTIL" detach -quiet -force "$MOUNT" > /dev/null 2>&1; then
        printf 'warning: could not detach %s; leaving %s in place\n' "$MOUNT" "$WORK" >&2
        keep=1
    fi
    if [[ -n "${RFM_DMG_KEEP_WORK:-}" ]]; then
        printf 'kept %s\n' "$WORK" >&2
        keep=1
    fi
    [[ -z "${PACKAGING:-}" ]] || rm -f "$PACKAGING/DS_Store.new"
    if [[ "$keep" -eq 0 ]]; then
        rm -rf "$WORK"
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 1' INT TERM HUP

say "installing dmgbuild into $VENV (pip needs the network)"
if [[ ! -x "$VENV/bin/python" ]]; then
    "$PYTHON3" -m venv "$VENV" || die "could not create the virtual environment $VENV"
fi
"$VENV/bin/python" -m pip install --disable-pip-version-check --no-input --quiet \
    --require-hashes -r "$PACKAGING/dmgbuild-requirements.txt" || die "pip could not install the pinned packages"

if [[ -z "$APP" ]]; then
    APP="$WORK/$APP_NAME"
    mkdir -p "$APP/Contents"
fi

say "building a throwaway image with dmgbuild"
"$VENV/bin/dmgbuild" -s "$PACKAGING/dmgbuild-settings.py" \
    -D "app=$APP" -D "background=$PACKAGING/background.png" \
    "$VOLUME_NAME" "$WORK/layout.dmg" > "$WORK/dmgbuild.log" 2>&1 || {
    cat "$WORK/dmgbuild.log" >&2
    die "dmgbuild failed"
}

say "reading the .DS_Store it wrote"
dmg_attach readonly "$WORK/layout.dmg" "$WORK/mount" || die "could not attach the throwaway image"
MOUNT="$WORK/mount"
[[ -f "$MOUNT/.DS_Store" ]] || die "dmgbuild's image has no .DS_Store"
cp "$MOUNT/.DS_Store" "$WORK/DS_Store"
dmg_detach "$MOUNT" || die "could not detach the throwaway image"
MOUNT=""

dmg_check_layout "$WORK/DS_Store" "$VOLUME_NAME" "$APP_NAME" Applications || exit 1
[[ "$(dmg_layout_field "icon:$APP_NAME")" == "$APP_POSITION" ]] ||
    die "the layout puts $APP_NAME at $(dmg_layout_field "icon:$APP_NAME"), not $APP_POSITION"
[[ "$(dmg_layout_field icon:Applications)" == "$APPLICATIONS_POSITION" ]] ||
    die "the layout puts Applications at $(dmg_layout_field icon:Applications), not $APPLICATIONS_POSITION"

# Replace the committed file only now, and in one step.
cp "$WORK/DS_Store" "$PACKAGING/DS_Store.new"
mv -f "$PACKAGING/DS_Store.new" "$PACKAGING/DS_Store"
say "wrote $PACKAGING/DS_Store"
printf '%s\n' "$DMG_LAYOUT"
