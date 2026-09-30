#!/bin/bash
# Pack a built RoomForMac.app as the archive Sparkle downloads for an update:
# RoomForMac-X.Y.Z.tar.xz with RoomForMac.app at its root (Ruling 4). The
# archive is unpacked again and the copy is verified, so an archive that could
# not survive an update is never published. Nothing is left behind on failure.
#
# release.yml runs this once per tag (Task 13); the update rehearsal runs it on
# its throwaway builds (Task 15). Only the codesign tool is called through a
# variable, so the tests can watch what it verifies.

set -euo pipefail

CODESIGN="${CODESIGN:-/usr/bin/codesign}"

usage() {
    cat << 'EOF'
Usage: scripts/make-update-archive.sh <RoomForMac.app> <out.tar.xz>

Writes <out.tar.xz>, a tar archive compressed with xz that holds RoomForMac.app
at its root, unpacks it into a temporary folder, and runs
`codesign --verify --deep --strict` on the copy. The output file appears only
when that passes.

stdout: "<out.tar.xz> <bytes> <sha256>". Exit status: 0 done; 1 the archive
could not be made or its copy does not verify; 2 usage error.
Environment: CODESIGN (default /usr/bin/codesign).
EOF
}

usage_error() {
    printf 'error: %s\n' "$*" >&2
    printf 'Run scripts/make-update-archive.sh --help for usage.\n' >&2
    exit 2
}
die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

case "${1:-}" in
    -h | --help)
        usage
        exit 0
        ;;
esac
[[ $# -eq 2 ]] || usage_error "expected <RoomForMac.app> <out.tar.xz>"
APP="${1%/}"
OUT="$2"
[[ "$(basename "$APP")" == "RoomForMac.app" ]] ||
    usage_error "the app must be named RoomForMac.app (got $(basename "$APP")): the archive keeps that name for every update"
[[ -d "$APP/Contents" ]] || usage_error "not an app bundle: $APP"
case "$OUT" in
    *.tar.xz) ;;
    *) usage_error "the archive name must end in .tar.xz: $OUT" ;;
esac
[[ -d "$(dirname "$OUT")" ]] || usage_error "the folder for $OUT does not exist"

TEMP_ROOT="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "${TEMP_ROOT%/}/rfm-update-archive.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# --no-xattrs is Sparkle's advice. On macOS it is not enough: tar still stores
# each file's extended attributes as AppleDouble "._" entries, which unpack
# into attributes again (quarantine, Finder information) and can fail strict
# verification. COPYFILE_DISABLE=1 stops that.
if ! COPYFILE_DISABLE=1 tar --no-xattrs -cJf "$WORK/archive.tar.xz" -C "$(dirname "$APP")" RoomForMac.app; then
    die "tar could not write the archive"
fi

mkdir "$WORK/extracted"
if ! tar -xJf "$WORK/archive.tar.xz" -C "$WORK/extracted"; then
    die "tar could not unpack the archive it just wrote"
fi
ROOT_ENTRIES="$(find "$WORK/extracted" -mindepth 1 -maxdepth 1 -exec basename {} \;)"
[[ "$ROOT_ENTRIES" == "RoomForMac.app" ]] ||
    die "the archive root must hold only RoomForMac.app, not: $(printf '%s' "$ROOT_ENTRIES" | tr '\n' ' ')"

if ! VERIFY_LOG="$("$CODESIGN" --verify --deep --strict "$WORK/extracted/RoomForMac.app" 2>&1)"; then
    printf '%s\n' "$VERIFY_LOG" >&2
    die "the unpacked copy of $APP fails strict verification, so the archive would not survive an update"
fi

mv -f "$WORK/archive.tar.xz" "$OUT"
BYTES="$(wc -c < "$OUT" | tr -d ' ')"
SHA256="$(shasum -a 256 "$OUT" | cut -d' ' -f1)"
printf '%s %s %s\n' "$OUT" "$BYTES" "$SHA256"
