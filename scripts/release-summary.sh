#!/bin/bash
# Print latest.json for a release: the one small file the site's download page
# reads (site/assets/download.js) to show the version, size and SHA-256 of the
# disk image behind the permanent RoomForMac.dmg link.
#
# It runs on macOS in the release build and on ubuntu-latest, so it uses only
# portable tools: no stat, no sed -i, no BSD-only or GNU-only flags.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/distribution.sh
source "$ROOT/scripts/lib/distribution.sh"
# shellcheck source=lib/version.sh
source "$ROOT/scripts/lib/version.sh"

# The lowest macOS this release runs on. make-appcast.sh states the same value
# for Sparkle, and check-release-app.sh pins the app's LSMinimumSystemVersion.
MINIMUM_MACOS="26.0"
# The release asset the site links to for life (identifiers fixed for life).
DMG_NAME="RoomForMac.dmg"

usage() {
    cat << 'EOF'
Usage: scripts/release-summary.sh --dmg <RoomForMac.dmg> --tag vX.Y.Z [--repository OWNER/NAME]

Prints latest.json on one line:
  {"schema":1,"version":"X.Y.Z","build":N,"minimum_macos":"26.0","date":"YYYY-MM-DD",
   "dmg":{"url":"https://github.com/OWNER/NAME/releases/download/vX.Y.Z/RoomForMac.dmg","size":BYTES,"sha256":"..."}}

The size and SHA-256 are those of the disk image given, which must be named
RoomForMac.dmg and not be empty. --repository defaults to RFM_REPOSITORY in
Config/Distribution.xcconfig. RFM_RELEASE_DATE (YYYY-MM-DD) replaces today's
UTC date; the tests use it.

Exit status: 0 done; 1 a check failed (not a strict vX.Y.Z tag, or a missing,
empty or misnamed disk image); 2 usage error.
EOF
}

usage_error() {
    printf 'error: %s\n' "$*" >&2
    printf 'Run scripts/release-summary.sh --help for usage.\n' >&2
    exit 2
}
die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

need_value() {
    if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
        usage_error "$1 needs a value"
    fi
}

DMG=""
TAG=""
REPOSITORY=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dmg)
            need_value "$@"
            DMG="$2"
            shift 2
            ;;
        --tag)
            need_value "$@"
            TAG="$2"
            shift 2
            ;;
        --repository)
            need_value "$@"
            REPOSITORY="$2"
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) usage_error "unknown argument: $1" ;;
    esac
done
[[ -n "$DMG" ]] || usage_error "--dmg is required"
[[ -n "$TAG" ]] || usage_error "--tag is required"

if [[ "$TAG" != v* ]] || ! version_is_release "${TAG#v}"; then
    die "the tag must be a strict vX.Y.Z (no leading zeros, minor and patch at most 999): $TAG"
fi
VERSION="${TAG#v}"
BUILD="$(build_number_for "$VERSION")"

if [[ -z "$REPOSITORY" ]]; then
    REPOSITORY="$(distribution_value "$ROOT" RFM_REPOSITORY)"
fi
# The value goes into a URL and into JSON without escaping, so it is restricted.
[[ "$REPOSITORY" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || usage_error "--repository must look like owner/name: $REPOSITORY"

DATE="${RFM_RELEASE_DATE:-$(date -u +%Y-%m-%d)}"
[[ "$DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || usage_error "RFM_RELEASE_DATE must be YYYY-MM-DD: $DATE"

[[ -f "$DMG" ]] || die "no such disk image: $DMG"
[[ "$(basename "$DMG")" == "$DMG_NAME" ]] ||
    die "the disk image must be named $DMG_NAME, the asset the site links to (got $(basename "$DMG"))"

# wc and a digest tool that exists on both runners: shasum comes with macOS and
# with ubuntu's perl, sha256sum with GNU coreutils.
SIZE="$(wc -c < "$DMG" | tr -d ' ')"
[[ "$SIZE" -gt 0 ]] || die "the disk image is empty: $DMG"
if command -v shasum > /dev/null 2>&1; then
    SHA256="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
else
    SHA256="$(sha256sum "$DMG" | cut -d' ' -f1)"
fi
[[ "$SHA256" =~ ^[0-9a-f]{64}$ ]] || die "could not compute the SHA-256 of $DMG"

printf '{"schema":1,"version":"%s","build":%s,"minimum_macos":"%s","date":"%s",' \
    "$VERSION" "$BUILD" "$MINIMUM_MACOS" "$DATE"
printf '"dmg":{"url":"https://github.com/%s/releases/download/%s/%s","size":%s,"sha256":"%s"}}\n' \
    "$REPOSITORY" "$TAG" "$DMG_NAME" "$SIZE" "$SHA256"
