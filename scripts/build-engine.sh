#!/bin/bash
# Build the patched Mole engine that RoomForMac bundles.
#
# Output:  $ENGINE_OUT (default build/engine): mole, bin/, lib/, host-bin/, LICENSE, VERSION
# Source:  build/engine-src: pinned Mole with patches/mole applied (kept for tests)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/vendor/mole"
PATCH_DIR="$ROOT/patches/mole"
SRC="$ROOT/build/engine-src"
OUT="${ENGINE_OUT:-$ROOT/build/engine}"
GIT_ID=(-c user.name="RoomForMac Build" -c user.email="build@roomformac.invalid")

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

for tool in git go lipo shasum; do
    command -v "$tool" > /dev/null 2>&1 || die "$tool is required (brew bundle --file Brewfile)"
done
[[ -e "$VENDOR/.git" ]] || die "vendor/mole is missing; run: git submodule update --init"

commit="$(git -C "$VENDOR" rev-parse HEAD)"
tag="$(git -C "$VENDOR" describe --tags --exact-match 2> /dev/null || echo untagged)"

rm -rf "$SRC"
mkdir -p "$ROOT/build"
git clone --quiet --no-local "$(git -C "$VENDOR" rev-parse --absolute-git-dir)" "$SRC"
git -C "$SRC" checkout --quiet --detach "$commit"

patches=()
for patch in "$PATCH_DIR"/*.patch; do
    if [[ -f "$patch" ]]; then
        patches+=("$patch")
    fi
done
patches_sha="none"
if [[ ${#patches[@]} -gt 0 ]]; then
    git -C "$SRC" "${GIT_ID[@]}" am --quiet --3way "${patches[@]}"
    patches_sha="$(cat "${patches[@]}" | shasum -a 256 | cut -d' ' -f1)"
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
# scripts/ensure-engine.sh. builder_sha256 lets it notice edits to this script.
builder_sha="$(shasum -a 256 "$ROOT/scripts/build-engine.sh" | cut -d' ' -f1)"
cat > "$OUT/VERSION" << VERSION
mole_tag=$tag
mole_commit=$commit
patches_sha256=$patches_sha
patch_count=${#patches[@]}
builder_sha256=$builder_sha
VERSION

printf 'Engine ready: %s (%s, %d patches)\n' "$OUT" "$tag" "${#patches[@]}"
