#!/bin/bash
# Pack the Corresponding Source of one release (Ruling 11). RoomForMac and its
# bundled engine are GPL-3.0, so every binary release carries the source it was
# built from. GitHub's automatic archives leave submodules out, so this makes
# the one that release.yml attaches (Task 13):
#
#   RoomForMac-X.Y.Z/                 the superproject at the tag
#   RoomForMac-X.Y.Z/vendor/mole/     the engine at the commit the tag records
#
# It reads git objects only: the tag, and the submodule commit that the tag's
# tree names, each archived with `git archive`. It never reads the working
# tree, so uncommitted edits, untracked files and a submodule checked out at
# another commit cannot end up in the archive.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/version.sh
source "$ROOT/scripts/lib/version.sh"

MOLE="vendor/mole"

usage() {
    cat << 'EOF'
Usage: scripts/make-source-archive.sh <vX.Y.Z> <out.tar.gz>

Writes <out.tar.gz> with RoomForMac-X.Y.Z/ holding the repository at the tag
and RoomForMac-X.Y.Z/vendor/mole/ holding the engine at the commit the tag
records for that submodule. The archive contains patches/mole/, LICENSE,
NOTICE and vendor/mole/LICENSE.

stdout: "<out.tar.gz> <bytes> <sha256>". Exit status: 0 done; 1 a check failed
(not a strict vX.Y.Z tag, an unknown tag, a submodule that is missing or lacks
the recorded commit, or a required file absent from the archive); 2 usage error.
The output file appears only on success.
EOF
}

usage_error() {
    printf 'error: %s\n' "$*" >&2
    printf 'Run scripts/make-source-archive.sh --help for usage.\n' >&2
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
[[ $# -eq 2 ]] || usage_error "expected <vX.Y.Z> <out.tar.gz>"
TAG="$1"
OUT="$2"
case "$OUT" in
    *.tar.gz) ;;
    *) usage_error "the archive name must end in .tar.gz: $OUT" ;;
esac
[[ -d "$(dirname "$OUT")" ]] || usage_error "the folder for $OUT does not exist"

if [[ "$TAG" != v* ]] || ! version_is_release "${TAG#v}"; then
    die "the tag must be a strict vX.Y.Z (no leading zeros, minor and patch at most 999): $TAG"
fi
PREFIX="RoomForMac-${TAG#v}"

TAG_COMMIT="$(git -C "$ROOT" rev-parse --verify --quiet "refs/tags/${TAG}^{commit}" || true)"
[[ -n "$TAG_COMMIT" ]] || die "the tag $TAG does not exist in $ROOT (fetch tags: git fetch --tags)"

# "160000 commit <sha>", a tab, then the path: the gitlink the tag's tree holds.
ENTRY="$(git -C "$ROOT" ls-tree "$TAG_COMMIT" -- "$MOLE")"
read -r MODE _ MOLE_COMMIT _ <<< "$ENTRY"
[[ "${MODE:-}" == "160000" ]] || die "the tag $TAG does not record $MOLE as a submodule"
[[ "$MOLE_COMMIT" =~ ^[0-9a-f]{40,64}$ ]] || die "the tag $TAG records an unreadable commit for $MOLE: $MOLE_COMMIT"

[[ -e "$ROOT/$MOLE/.git" ]] || die "$MOLE is not checked out; run: git submodule update --init"
git -C "$ROOT/$MOLE" cat-file -e "${MOLE_COMMIT}^{commit}" 2> /dev/null ||
    die "$MOLE has no commit $MOLE_COMMIT, which $TAG records; fetch it there or run: git submodule update --init"

TEMP_ROOT="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "${TEMP_ROOT%/}/rfm-source-archive.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/tree"

# git archive writes a submodule as an empty folder, and the engine's archive
# unpacks into it.
git -C "$ROOT" archive --format=tar --prefix="$PREFIX/" "$TAG_COMMIT" | tar -xf - -C "$WORK/tree"
git -C "$ROOT/$MOLE" archive --format=tar --prefix="$PREFIX/$MOLE/" "$MOLE_COMMIT" | tar -xf - -C "$WORK/tree"

TREE="$WORK/tree/$PREFIX"
for required in LICENSE NOTICE "$MOLE/LICENSE"; do
    [[ -f "$TREE/$required" ]] || die "the source archive has no $required at $TAG"
done
[[ -n "$(find "$TREE/patches/mole" -name '*.patch' -print 2> /dev/null)" ]] ||
    die "the source archive has no patches/mole/*.patch at $TAG, so it could not rebuild the engine"

# gzip -n leaves the file name and time out of the header. COPYFILE_DISABLE and
# --no-xattrs keep macOS from adding "._" copies of extended attributes.
if ! COPYFILE_DISABLE=1 tar --no-xattrs -C "$WORK/tree" -cf - "$PREFIX" | gzip -n -9 > "$WORK/source.tar.gz"; then
    die "tar or gzip could not write the archive"
fi

mv -f "$WORK/source.tar.gz" "$OUT"
BYTES="$(wc -c < "$OUT" | tr -d ' ')"
SHA256="$(shasum -a 256 "$OUT" | cut -d' ' -f1)"
printf '%s %s %s\n' "$OUT" "$BYTES" "$SHA256"
