#!/bin/bash
# Xcode "Embed engine" phase of the RoomForMac target. Xcode signs the app
# after every build phase, so this runs before the app's CodeSign step.
#
#   $RFM_ENGINE_DIR (build/engine)  ->  Contents/Resources/engine
#   engine/bin Mach-O tools         ->  Contents/Helpers, symlinked back into engine/bin
#
# Each tool is signed with the identity Xcode signs the app with, as
# <bundle id>.engine.<tool>. Contents/Helpers belongs to this phase.

set -euo pipefail

src="${RFM_ENGINE_DIR:?}"
dest="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/engine"
helpers="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH:?}/Helpers"
stamp="${DERIVED_FILE_DIR:?}/embed-engine.stamp"

if [[ ! -f "$src/VERSION" ]]; then
    echo "error: no engine at $src; run scripts/build-engine.sh" >&2
    exit 1
fi

# Skip when neither the engine, the signing inputs, the destination nor this
# script changed, so a no-op build leaves the signed bundle alone.
fingerprint="$({
    (cd "$src" && find . -print0 | LC_ALL=C sort -z | xargs -0 stat -f '%N %z %m %p %Y')
    echo "${CODE_SIGNING_ALLOWED:-} ${EXPANDED_CODE_SIGN_IDENTITY:-} ${ENABLE_HARDENED_RUNTIME:-}"
    echo "${PRODUCT_BUNDLE_IDENTIFIER:-} $dest"
    cat "$0"
} | shasum -a 256)"
if [[ -f "$stamp" && "$(cat "$stamp")" == "$fingerprint" && -f "$dest/VERSION" && -d "$helpers" ]]; then
    echo "Engine already embedded"
    exit 0
fi

rm -rf "$dest" "$helpers"
mkdir -p "$dest" "$helpers"
/usr/bin/ditto --norsrc --noextattr --noacl "$src" "$dest"

while IFS= read -r -d '' file; do
    if ! /usr/bin/lipo -archs "$file" > /dev/null 2>&1; then
        continue # a script: stays in Resources, sealed as a resource
    fi
    if [[ "$(dirname "$file")" != "$dest/bin" ]]; then
        echo "error: Mach-O outside engine/bin: $file" >&2
        exit 1
    fi
    name="$(basename "$file")"
    mv "$file" "$helpers/$name"
    ln -s "../../../Helpers/$name" "$file"
    if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" ]]; then
        flags=(--force --sign "${EXPANDED_CODE_SIGN_IDENTITY:?}" --timestamp=none
            --identifier "${PRODUCT_BUNDLE_IDENTIFIER:?}.engine.$name")
        if [[ "${ENABLE_HARDENED_RUNTIME:-NO}" == "YES" ]]; then
            flags+=(--options runtime)
        fi
        /usr/bin/codesign "${flags[@]}" "$helpers/$name"
    fi
    echo "Embedded $name"
done < <(find "$dest" -type f -perm -u+x -print0)

# VERSION is this phase's declared output. Xcode re-signs the app only when a
# declared output changes, and ditto keeps the source mtime, so touch it.
touch "$dest/VERSION"
mkdir -p "$(dirname "$stamp")"
echo "$fingerprint" > "$stamp"
