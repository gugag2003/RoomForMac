#!/bin/bash
# Xcode "Prepare Sparkle" phase of the RoomForMac target. Xcode has just copied
# Sparkle.framework into the app and signed it (project.yml declares two of the
# files that step writes as this phase's inputs, so the phase waits for it), and
# it signs the app after every build phase, so this runs between the two.
#
# Sparkle's XPC services exist for sandboxed apps. RoomForMac is not sandboxed,
# and Sparkle says not to enable them there, so they are deleted. That breaks
# the framework's seal, so its nested code is signed again, inside out, with
# the identity Xcode signs the app with:
#
#   Versions/B/Autoupdate  ->  Versions/B/Updater.app  ->  Sparkle.framework
#
# Never --deep: it signs everything with one set of options and hides a nested
# piece that failed. Hardened runtime follows the app's own setting. The
# identifier each piece already has is kept, and its entitlements are not:
# Sparkle's own Autoupdate carries an application-identifier entitlement that
# only an Apple-issued profile can back.
#
# Reads Xcode's TARGET_BUILD_DIR, FRAMEWORKS_FOLDER_PATH, DERIVED_FILE_DIR,
# CODE_SIGNING_ALLOWED, EXPANDED_CODE_SIGN_IDENTITY and ENABLE_HARDENED_RUNTIME.
# CODESIGN overrides the tool (tests stub it). Xcode passes ACTION.

set -euo pipefail

if [[ "${ACTION:-}" == "indexbuild" ]]; then
    echo "Index build: not preparing Sparkle"
    exit 0
fi

codesign="${CODESIGN:-/usr/bin/codesign}"
framework="${TARGET_BUILD_DIR:?}/${FRAMEWORKS_FOLDER_PATH:?}/Sparkle.framework"
versions="$framework/Versions/B"
stamp="${DERIVED_FILE_DIR:?}/prepare-sparkle.stamp"
# The phase's declared output (project.yml). Xcode signs the app again only when
# a declared output changes, and re-signing the framework changes no file
# Xcode watches, so touch this one after signing.
output="$versions/Autoupdate"

if [[ ! -f "$versions/Autoupdate" || ! -d "$versions/Updater.app" ]]; then
    echo "error: unexpected Sparkle.framework layout: no Versions/B/Autoupdate or Versions/B/Updater.app in $framework" >&2
    exit 1
fi

# The framework as it is now, what signs it and this script. The stamp holds
# this value for the finished framework, so a build that changed nothing skips
# the work, and a framework that Xcode copied again (its XPC services back, its
# signature Sparkle's own) does not.
fingerprint() {
    {
        (cd "$framework" && find . -print0 | LC_ALL=C sort -z | xargs -0 stat -f '%N %z %Fm %p %Y')
        echo "${CODE_SIGNING_ALLOWED:-} ${EXPANDED_CODE_SIGN_IDENTITY:-} ${ENABLE_HARDENED_RUNTIME:-}"
        cat "$0"
    } | shasum -a 256 | cut -d' ' -f1
}

if [[ -f "$stamp" && "$(cat "$stamp")" == "$(fingerprint)" ]]; then
    echo "Sparkle already prepared"
    exit 0
fi

# An interrupted run must never look finished.
rm -f "$stamp"

rm -rf "$versions/XPCServices" "$framework/XPCServices"

if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" ]]; then
    flags=(--force --sign "${EXPANDED_CODE_SIGN_IDENTITY:?}" --timestamp=none)
    if [[ "${ENABLE_HARDENED_RUNTIME:-NO}" == "YES" ]]; then
        flags+=(--options runtime)
    fi
    flags+=(--preserve-metadata=identifier)
    for piece in "$versions/Autoupdate" "$versions/Updater.app" "$framework"; do
        "$codesign" "${flags[@]}" "$piece"
        echo "Signed $(basename "$piece")"
    done
fi

touch "$output"
mkdir -p "$(dirname "$stamp")"
fingerprint > "$stamp"
echo "Prepared Sparkle"
