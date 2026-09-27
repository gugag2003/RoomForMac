#!/bin/bash
# What a built engine depends on besides vendor/mole's commit. build-engine.sh
# records these values in VERSION and ensure-engine.sh compares VERSION with
# them. Both source this one definition: if the two ever computed them
# differently, every build would rebuild the engine.
#
#   engine_inputs ROOT   sets, for the checkout at ROOT:
#     engine_patches         patches/mole/*.patch in glob order (an array)
#     engine_patches_sha256  sha256 of those patches concatenated, or "none"
#     engine_builder_sha256  sha256 of scripts/build-engine.sh followed by this
#                            file, since both shape the build
#
# Sourcing it defines the function only; it sets no shell options.

# shellcheck disable=SC2034 # the variables are read by the sourcing script
engine_inputs() {
    local root="$1" patch
    engine_patches=()
    for patch in "$root"/patches/mole/*.patch; do
        if [[ -f "$patch" ]]; then
            engine_patches+=("$patch")
        fi
    done
    engine_patches_sha256="none"
    if [[ ${#engine_patches[@]} -gt 0 ]]; then
        engine_patches_sha256="$(cat "${engine_patches[@]}" | shasum -a 256 | cut -d' ' -f1)"
    fi
    engine_builder_sha256="$(cat "$root/scripts/build-engine.sh" "$root/scripts/lib/engine-inputs.sh" |
        shasum -a 256 | cut -d' ' -f1)"
}
