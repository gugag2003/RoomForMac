#!/bin/bash
# Build the patched Mole engine that RoomForMac bundles.
#
# Output:  $ENGINE_OUT (default build/engine): mole, bin/, lib/, host-bin/, LICENSE, VERSION
# Source:  build/engine-src: pinned Mole with patches/mole applied (kept for tests)
#
# Every build re-clones build/engine-src, so only one runs at a time: a second
# build waits for the build/.engine.lock directory, retrying every second for
# RFM_ENGINE_LOCK_TIMEOUT seconds (default 600), then fails.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/vendor/mole"
SRC="$ROOT/build/engine-src"
OUT="${ENGINE_OUT:-$ROOT/build/engine}"
LOCK="$ROOT/build/.engine.lock"
LOCK_TIMEOUT="${RFM_ENGINE_LOCK_TIMEOUT:-600}"
GIT_ID=(-c user.name="RoomForMac Build" -c user.email="build@roomformac.invalid")

# shellcheck source=lib/engine-inputs.sh
source "$ROOT/scripts/lib/engine-inputs.sh"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

for tool in git go lipo shasum; do
    command -v "$tool" > /dev/null 2>&1 || die "$tool is required (brew bundle --file Brewfile)"
done
[[ -e "$VENDOR/.git" ]] || die "vendor/mole is missing; run: git submodule update --init"
[[ "$LOCK_TIMEOUT" =~ ^[0-9]+$ ]] || die "RFM_ENGINE_LOCK_TIMEOUT must be a whole number of seconds"

# mkdir is atomic: exactly one build creates the lock. The trap is set only
# once this build holds it, so a build that gives up leaves the lock alone.
mkdir -p "$ROOT/build"
waited=0
until mkdir "$LOCK" 2> /dev/null; do
    if [[ $waited -ge $LOCK_TIMEOUT ]]; then
        die "another engine build still holds $LOCK after ${waited}s; if no engine build is running, remove it: rm -rf $(printf %q "$LOCK")"
    fi
    if [[ $waited -eq 0 ]]; then
        echo "Waiting for another engine build to finish ($LOCK)"
    fi
    sleep 1
    waited=$((waited + 1))
done
trap 'rm -rf "$LOCK"' EXIT

commit="$(git -C "$VENDOR" rev-parse HEAD)"
tag="$(git -C "$VENDOR" describe --tags --exact-match 2> /dev/null || echo untagged)"
engine_inputs "$ROOT"

rm -rf "$SRC"
git clone --quiet --no-local "$(git -C "$VENDOR" rev-parse --absolute-git-dir)" "$SRC"
git -C "$SRC" checkout --quiet --detach "$commit"

if [[ ${#engine_patches[@]} -gt 0 ]]; then
    git -C "$SRC" "${GIT_ID[@]}" am --quiet --3way "${engine_patches[@]}"
fi

build_universal() {
    local name="$1" package="$2" arch
    for arch in arm64 amd64; do
        (cd "$SRC" && CGO_ENABLED=0 GOOS=darwin GOARCH="$arch" \
            go build -trimpath -ldflags="-s -w" -o "bin/$name.$arch" "$package")
    done
    lipo -create -output "$SRC/bin/$name" "$SRC/bin/$name.arm64" "$SRC/bin/$name.amd64"
    rm -f "$SRC/bin/$name.arm64" "$SRC/bin/$name.amd64"
}
build_universal analyze-go ./cmd/analyze
build_universal status-go ./cmd/status

rm -rf "$OUT"
mkdir -p "$OUT/bin" "$OUT/host-bin"
cp "$SRC/mole" "$OUT/mole"
cp "$SRC"/bin/*.sh "$OUT/bin/"
cp "$SRC/bin/analyze-go" "$SRC/bin/status-go" "$OUT/bin/"
cp -R "$SRC/lib" "$OUT/lib"
chmod +x "$OUT/mole" "$OUT"/bin/*

cat > "$OUT/host-bin/sudo" << 'SHIM'
#!/bin/bash
# RoomForMac runs the engine without administrator access. Every sudo call
# fails at once, so neither a password prompt nor a cached ticket is used.
exit 1
SHIM
chmod +x "$OUT/host-bin/sudo"

# GPL-3.0: the engine ships with Mole's license text.
cp "$VENDOR/LICENSE" "$OUT/LICENSE"

# VERSION is written last, so an interrupted build never looks complete to
# scripts/ensure-engine.sh. builder_sha256 lets it notice edits to this script
# and to lib/engine-inputs.sh.
cat > "$OUT/VERSION" << VERSION
mole_tag=$tag
mole_commit=$commit
patches_sha256=$engine_patches_sha256
patch_count=${#engine_patches[@]}
builder_sha256=$engine_builder_sha256
VERSION

printf 'Engine ready: %s (%s, %d patches)\n' "$OUT" "$tag" "${#engine_patches[@]}"
