#!/bin/bash
# Xcode "Prepare engine" phase, step 1: make sure the engine matches the
# pinned Mole commit, patches/mole, scripts/build-engine.sh and
# scripts/lib/engine-inputs.sh, and rebuild it only when one of them changed.
# About 0.1 s when nothing changed.
#
#   RFM_ENGINE_DIR       engine directory (default build/engine; Xcode sets it)
#   RFM_NO_ENGINE_BUILD  1 = fail instead of building a missing or stale engine
#   ACTION               Xcode's build action; an index build ("indexbuild")
#                        never builds the engine, so it cannot race a real build

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="${RFM_ENGINE_DIR:-$ROOT/build/engine}"
# Xcode started from the Dock has no Homebrew on PATH, and build-engine.sh
# needs go from there.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# shellcheck source=lib/engine-inputs.sh
source "$ROOT/scripts/lib/engine-inputs.sh"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

[[ -e "$ROOT/vendor/mole/.git" ]] || die "vendor/mole is missing; run: git submodule update --init"

expected_commit="$(git -C "$ROOT/vendor/mole" rev-parse HEAD)"
engine_inputs "$ROOT"

value() { sed -n "s/^$1=//p" "$ENGINE/VERSION" 2> /dev/null || true; }
current="$(value mole_commit) $(value patches_sha256) $(value builder_sha256)"
if [[ "$current" == "$expected_commit $engine_patches_sha256 $engine_builder_sha256" ]]; then
    echo "Engine is up to date: $ENGINE"
    exit 0
fi
# Xcode runs this phase for its background index builds too. Only a real build
# may start the minute-long engine build.
if [[ "${ACTION:-}" == "indexbuild" ]]; then
    echo "Index build: not building the engine"
    exit 0
fi
if [[ "${RFM_NO_ENGINE_BUILD:-0}" == "1" ]]; then
    die "$ENGINE is missing or stale; run scripts/build-engine.sh"
fi
echo "Engine is missing or stale; building it (about a minute)"
ENGINE_OUT="$ENGINE" "$ROOT/scripts/build-engine.sh"
