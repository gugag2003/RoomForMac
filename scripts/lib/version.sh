#!/bin/bash
# RoomForMac's version numbers (Plan 6, Ruling 10).
#
#   version_is_release X.Y.Z   exit 0 for a strict release version: three
#                              numbers without leading zeros, X at most 2000,
#                              Y and Z at most 999. Nothing else passes: not
#                              "v1.2.3", "1.2", "1.2.3-beta" or a padded string.
#   build_number_for X.Y.Z     prints X*1000000 + Y*1000 + Z, the value of
#                              CFBundleVersion. 0.1.0 is 1000, 1.2.3 is 1002003,
#                              and the largest, 2000.999.999, is 2000999999,
#                              which still fits in 32 bits. It prints an error
#                              and returns 1 for anything version_is_release
#                              refuses.
#
# Sparkle compares CFBundleVersion and refuses to install a lower one, so a
# build number may only ever grow. Never change this formula to one that gives
# a published version a smaller number: every installed copy would refuse the
# update. Switching to a scheme that gives larger numbers is safe.
#
# Failures return 1 instead of calling exit, so a caller that invokes a
# function directly keeps running; through $(...), run or || the status is 1.
# Sourcing this file defines functions only; it sets no shell options.

version_is_release() {
    local version="${1-}"
    # shellcheck disable=SC2034 # zsh's =~ writes these into the caller's scope; bash never sets them
    local MATCH MBEGIN MEND match mbegin mend
    local pattern='^(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$'
    [[ "$version" =~ $pattern ]] || return 1
    [[ "${version%%.*}" -le 2000 ]]
}

build_number_for() {
    local version="${1-}"
    if ! version_is_release "$version"; then
        printf 'error: not a release version (X.Y.Z, X up to 2000, Y and Z up to 999, no leading zeros): %s\n' \
            "$version" >&2
        return 1
    fi
    local major minor patch rest
    major="${version%%.*}"
    rest="${version#*.}"
    minor="${rest%%.*}"
    patch="${rest#*.}"
    printf '%s\n' "$((major * 1000000 + minor * 1000 + patch))"
}
