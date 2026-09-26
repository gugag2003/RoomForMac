#!/bin/bash
# Maintain RoomForMac's patch queue on top of the pinned Mole release.
#
#   start                  Create build/mole-work: pinned Mole with patches/mole/*.patch
#                          applied as commits on branch "roomformac". Edit and commit there.
#   export                 Rewrite patches/mole/*.patch from those commits.
#   test [--tree DIR] F…   Run bats files inside a patched tree (default build/mole-work).
#   lint FILE…             shellcheck + shfmt check (paths relative to build/mole-work).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/vendor/mole"
WORK="$ROOT/build/mole-work"
PATCH_DIR="$ROOT/patches/mole"
GIT_ID=(-c user.name="RoomForMac Patches" -c user.email="patches@roomformac.invalid")

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

pinned_commit() {
    git -C "$VENDOR" rev-parse HEAD
}

cmd_start() {
    [[ ! -e "$WORK" ]] || die "$WORK already exists; keep working there or delete it first"
    mkdir -p "$ROOT/build"
    git clone --quiet --no-local "$(git -C "$VENDOR" rev-parse --absolute-git-dir)" "$WORK"
    git -C "$WORK" checkout --quiet -b roomformac "$(pinned_commit)"
    local -a patches=()
    local patch
    for patch in "$PATCH_DIR"/*.patch; do
        if [[ -f "$patch" ]]; then
            patches+=("$patch")
        fi
    done
    if [[ ${#patches[@]} -gt 0 ]]; then
        git -C "$WORK" "${GIT_ID[@]}" am --quiet --3way "${patches[@]}"
    fi
    printf 'Ready: %s (branch roomformac, %d patches applied)\n' "$WORK" "${#patches[@]}"
}

cmd_export() {
    [[ -d "$WORK/.git" ]] || die "run 'scripts/mole-patches.sh start' first"
    [[ -z "$(git -C "$WORK" status --porcelain)" ]] || die "$WORK has uncommitted changes"
    mkdir -p "$PATCH_DIR"
    find "$PATCH_DIR" -name '*.patch' -delete
    # --no-numbered keeps each subject "[PATCH]", so adding a patch never
    # rewrites the ones before it.
    git -C "$WORK" format-patch --quiet --zero-commit --no-signature --no-numbered \
        -o "$PATCH_DIR" "$(pinned_commit)..roomformac"
    ls -1 "$PATCH_DIR"
}

cmd_test() {
    local tree="$WORK"
    if [[ "${1:-}" == "--tree" ]]; then
        [[ $# -ge 2 ]] || die "--tree needs a directory"
        tree="$2"
        shift 2
    fi
    [[ -d "$tree/tests" ]] || die "no patched Mole tree at $tree"
    [[ $# -gt 0 ]] || die "usage: scripts/mole-patches.sh test [--tree DIR] tests/<file>.bats..."
    (cd "$tree" && MOLE_TEST_NO_AUTH=1 bats "$@")
}

cmd_lint() {
    [[ $# -gt 0 ]] || die "usage: scripts/mole-patches.sh lint <file.sh>..."
    (cd "$WORK" && shellcheck -x "$@" && shfmt -d -i 4 -ci -sr "$@")
}

case "${1:-}" in
    start) shift && cmd_start "$@" ;;
    export) shift && cmd_export "$@" ;;
    test) shift && cmd_test "$@" ;;
    lint) shift && cmd_lint "$@" ;;
    *) die "usage: scripts/mole-patches.sh start|export|test|lint" ;;
esac
