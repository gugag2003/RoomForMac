#!/bin/bash
# The Sparkle release RoomForMac is built against, and where its command-line
# tools are. The release scripts (make-update-keys.sh, make-appcast.sh,
# rehearse-update.sh) source this file. project.yml's exactVersion must equal
# SPARKLE_VERSION; distribution.bats pins that.
#
#   sparkle_bin ROOT   prints the folder holding generate_appcast, sign_update
#                      and generate_keys, taken from the first of these that
#                      holds all three tools:
#                        1. $SPARKLE_BIN, as given (tests point it at stubs)
#                        2. ROOT/build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin
#                           (CI and the release build)
#                        3. the newest ~/Library/Developer/Xcode/DerivedData/RoomForMac-*/
#                           SourcePackages/artifacts/sparkle/Sparkle/bin (a local build)
#                      Candidates 2 and 3 count only when the Sparkle.xcframework
#                      beside their bin folder reports SPARKLE_VERSION, so a tool
#                      from another release is never used. Exit 1, with the
#                      message "build the app once so Swift Package Manager
#                      fetches Sparkle", when there is none.
#
# Sourcing it defines variables and functions only; it sets no shell options.

SPARKLE_VERSION=2.10.0

# sparkle_bin_ok BIN: 0 when BIN holds the three tools and the xcframework
# beside it is Sparkle SPARKLE_VERSION.
sparkle_bin_ok() {
    local bin="$1" tool plist version
    for tool in generate_appcast sign_update generate_keys; do
        if [[ ! -x "$bin/$tool" ]]; then
            return 1
        fi
    done
    for plist in "$bin"/../Sparkle.xcframework/*/Sparkle.framework/Versions/B/Resources/Info.plist; do
        if [[ ! -f "$plist" ]]; then
            continue
        fi
        version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$plist" 2> /dev/null)" || continue
        if [[ "$version" == "$SPARKLE_VERSION" ]]; then
            return 0
        fi
    done
    return 1
}

sparkle_bin() {
    local root="${1:?sparkle_bin ROOT}" candidate best=""
    local artifact="SourcePackages/artifacts/sparkle/Sparkle/bin"
    if [[ -n "${SPARKLE_BIN:-}" ]]; then
        if [[ ! -d "$SPARKLE_BIN" ]]; then
            echo "error: SPARKLE_BIN=$SPARKLE_BIN is not a folder" >&2
            return 1
        fi
        printf '%s\n' "$SPARKLE_BIN"
        return 0
    fi
    if sparkle_bin_ok "$root/build/DerivedData/$artifact"; then
        printf '%s\n' "$root/build/DerivedData/$artifact"
        return 0
    fi
    for candidate in "$HOME"/Library/Developer/Xcode/DerivedData/RoomForMac-*/"$artifact"; do
        if ! sparkle_bin_ok "$candidate"; then
            continue
        fi
        if [[ -z "$best" || "$candidate" -nt "$best" ]]; then
            best="$candidate"
        fi
    done
    if [[ -n "$best" ]]; then
        printf '%s\n' "$best"
        return 0
    fi
    echo "error: Sparkle $SPARKLE_VERSION's tools were not found; build the app once so Swift Package Manager fetches Sparkle" >&2
    return 1
}
