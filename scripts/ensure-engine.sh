#!/bin/bash
# Xcode "Prepare engine" phase, step 1: make sure the engine matches the
# pinned Mole commit, patches/mole and scripts/build-engine.sh, and rebuild it
# only when one of them changed. About 0.1 s when nothing changed.
#
#   RFM_ENGINE_DIR       engine directory (default build/engine; Xcode sets it)
#   RFM_NO_ENGINE_BUILD  1 = fail instead of building a missing or stale engine

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="${RFM_ENGINE_DIR:-$ROOT/build/engine}"
# Xcode started from the Dock has no Homebrew on PATH, and build-engine.sh
# needs go from there.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

[[ -e "$ROOT/vendor/mole/.git" ]] || die "vendor/mole is missing; run: git submodule update --init"

expected_commit="$(git -C "$ROOT/vendor/mole" rev-parse HEAD)"
patches=()
for patch in "$ROOT"/patches/mole/*.patch; do
    if [[ -f "$patch" ]]; then
        patches+=("$patch")
    fi
done
expected_sha="none"
if [[ ${#patches[@]} -gt 0 ]]; then
    expected_sha="$(cat "${patches[@]}" | shasum -a 256 | cut -d' ' -f1)"
fi
expected_builder="$(shasum -a 256 "$ROOT/scripts/build-engine.sh" | cut -d' ' -f1)"

value() { sed -n "s/^$1=//p" "$ENGINE/VERSION" 2> /dev/null || true; }
current="$(value mole_commit) $(value patches_sha256) $(value builder_sha256)"
if [[ "$current" == "$expected_commit $expected_sha $expected_builder" ]]; then
    echo "Engine is up to date: $ENGINE"
    exit 0
fi
if [[ "${RFM_NO_ENGINE_BUILD:-0}" == "1" ]]; then
    die "$ENGINE is missing or stale; run scripts/build-engine.sh"
fi
echo "Engine is missing or stale; building it (about a minute)"
ENGINE_OUT="$ENGINE" "$ROOT/scripts/build-engine.sh"
