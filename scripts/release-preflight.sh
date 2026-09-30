#!/bin/bash
# The checks that must pass before release.yml builds anything. Every failed
# check prints one "::error::" line to stderr, and all of them run, so one run
# shows everything that is wrong. On success, and only then, stdout carries the
# KEY=VALUE lines that release.yml appends to $GITHUB_ENV:
#
#   TAG=vX.Y.Z  VERSION=X.Y.Z  BUILD_NUMBER=N  ARCHIVE_NAME=RoomForMac-X.Y.Z.tar.xz
#   SOURCE_NAME=RoomForMac-X.Y.Z-source.tar.gz  STRICT_RELEASE=0|1  DRY_RUN=0|1
#   APP=build/DerivedData/Build/Products/Release/RoomForMac.app
#
#   scripts/release-preflight.sh <vX.Y.Z>           tag mode: a pushed release tag
#   scripts/release-preflight.sh --dry-run <X.Y.Z>  dry run: workflow_dispatch, or local
#
# Tag mode reads:
#   DEFAULT_BRANCH       the repository's default branch (required)
#   PUBLISHED_TAGS_FILE  one published release tag per line, may be empty (required)
#   VISIBILITY           the repository's visibility; must be PUBLIC (required)
#   GITHUB_REPOSITORY    optional; when set, it must equal RFM_REPOSITORY
#
# Tag mode checks that the tag is a strict vX.Y.Z tag that exists, that HEAD is
# its commit and that the commit is on origin/$DEFAULT_BRANCH (this needs a full
# checkout, fetch-depth: 0). It must be the newest release tag by sort -V and
# newer than every published one. Then come the checks both modes share:
# release-notes/X.Y.Z.md exists, has content, has no TODO, still has the
# template's closing licence paragraph and no leftover placeholder line;
# Config/signing-identity.sha1 is 40 hex digits and a newline; and
# RFM_SPARKLE_PUBLIC_KEY is set. Tag mode ends with the visibility and
# repository checks.
#
# A dry run skips the tag, branch, published, visibility and repository checks,
# not the shared ones. Without release-notes/X.Y.Z.md it checks
# release-notes/TEMPLATE.md instead, and says so.
#
# STRICT_RELEASE is 1 exactly when X is 1 or more. It only makes stage-site.sh
# refuse [OWNER: ...] placeholders; nothing here depends on Plan 5.
#
# Exit: 0 all checks passed; 1 a check failed; 2 usage error.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/distribution.sh
source "$ROOT/scripts/lib/distribution.sh"
# shellcheck source=lib/version.sh
source "$ROOT/scripts/lib/version.sh"

APP_PATH="build/DerivedData/Build/Products/Release/RoomForMac.app"
# The first sentence of the closing paragraph that release-notes/README.md
# requires in every release's notes; release-notes/TEMPLATE.md carries it.
LICENCE_SENTENCE="RoomForMac is free software under the GNU General Public License, version 3."
# Part of the placeholder lines in release-notes/TEMPLATE.md.
PLACEHOLDER="Replace this line"

failures=0

usage() {
    cat << 'USAGE'
Usage: scripts/release-preflight.sh <vX.Y.Z>
       scripts/release-preflight.sh --dry-run <X.Y.Z>
       scripts/release-preflight.sh --help
USAGE
}

usage_error() {
    printf 'error: %s\n' "$*" >&2
    usage >&2
    exit 2
}

# printable TEXT: TEXT with everything but printable ASCII replaced by "?". A tag
# or version comes from outside, and a newline in it must not start a second
# workflow command in the log.
printable() {
    printf '%s' "$*" | LC_ALL=C tr -c '[:print:]' '?'
}

fail() {
    failures=$((failures + 1))
    printf '::error::%s\n' "$(printable "$*")" >&2
}

notice() {
    printf '::notice::%s\n' "$(printable "$*")" >&2
}

# is_release_version X.Y.Z: version_is_release, after a case that keeps anything
# but digits and dots away from the library and from the lines that end up in
# $GITHUB_ENV. The digits are spelled out because a range can match other
# characters in some locales.
is_release_version() {
    case "$1" in
        '' | *[!0123456789.]*) return 1 ;;
    esac
    version_is_release "$1"
}

is_release_tag() {
    case "$1" in
        v?*) is_release_version "${1#v}" ;;
        *) return 1 ;;
    esac
}

# newest_release_tag: reads names on stdin, ignores every one that is not a
# strict vX.Y.Z tag, and prints the newest of the rest by sort -V.
newest_release_tag() {
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        if is_release_tag "$line"; then
            printf '%s\n' "$line"
        fi
    done | sort -V | tail -n 1
}

# check_tag: the checks that need git and the tag.
check_tag() {
    local commit head_commit origin_ref newest published_newest
    commit="$(git -C "$ROOT" rev-parse --verify --quiet "refs/tags/$tag^{commit}" 2> /dev/null || true)"
    if [[ -z "$commit" ]]; then
        fail "tag $tag does not exist"
    else
        head_commit="$(git -C "$ROOT" rev-parse --verify --quiet HEAD 2> /dev/null || true)"
        if [[ "$head_commit" != "$commit" ]]; then
            fail "HEAD is not the commit of $tag (${commit:0:12}); check out the tag"
        fi
        origin_ref="refs/remotes/origin/$DEFAULT_BRANCH"
        if ! git -C "$ROOT" rev-parse --verify --quiet "$origin_ref^{commit}" > /dev/null 2>&1; then
            fail "origin/$DEFAULT_BRANCH was not found; check out with fetch-depth: 0 and name the repository's default branch"
        elif ! git -C "$ROOT" merge-base --is-ancestor "$commit" "$origin_ref"; then
            fail "$tag is not on origin/$DEFAULT_BRANCH; tag a commit that is part of the default branch"
        fi
    fi

    newest="$({
        git -C "$ROOT" tag --list 'v*' || true
        printf '%s\n' "$tag"
    } | newest_release_tag)"
    if [[ "$newest" != "$tag" ]]; then
        fail "$newest is newer than $tag; a release must be the newest release tag"
    fi

    published_newest="$(newest_release_tag < "$PUBLISHED_TAGS_FILE")"
    if [[ "$published_newest" == "$tag" ]]; then
        fail "$tag is already published"
    elif [[ -n "$published_newest" && "$(printf '%s\n%s\n' "$published_newest" "$tag" | sort -V | tail -n 1)" != "$tag" ]]; then
        fail "$published_newest is already published and is newer than $tag"
    fi
}

check_notes() {
    local file="release-notes/$version.md" using_template=0 normalized
    if [[ ! -f "$ROOT/$file" && "$dry_run" -eq 1 ]]; then
        file="release-notes/TEMPLATE.md"
        using_template=1
        notice "dry run: release-notes/$version.md does not exist yet, so $file is checked instead"
    fi
    if [[ ! -f "$ROOT/$file" ]]; then
        fail "$file is missing"
        return 0
    fi
    if ! LC_ALL=C grep -q '[^[:space:]]' "$ROOT/$file"; then
        fail "$file is empty"
        return 0
    fi
    if LC_ALL=C grep -q 'TODO' "$ROOT/$file"; then
        fail "$file contains TODO"
    fi
    normalized="$(LC_ALL=C tr -s '[:space:]' ' ' < "$ROOT/$file")"
    if [[ "$normalized" != *"$LICENCE_SENTENCE"* ]]; then
        fail "$file does not contain the closing licence paragraph; copy it from release-notes/TEMPLATE.md"
    fi
    if [[ "$using_template" -eq 0 ]] && LC_ALL=C grep -qF "$PLACEHOLDER" "$ROOT/$file"; then
        fail "$file still contains the template's placeholder line"
    fi
}

check_identity_file() {
    local file="Config/signing-identity.sha1" size first
    if [[ ! -f "$ROOT/$file" ]]; then
        fail "$file is missing; create it with: scripts/make-signing-identity.sh --check | cut -d' ' -f1 > $file"
        return 0
    fi
    size="$(wc -c < "$ROOT/$file" | tr -d ' ')"
    first="$(head -n 1 "$ROOT/$file")"
    if [[ "$size" != 41 ]] || ! LC_ALL=C grep -Eq '^[0-9A-Fa-f]{40}$' <<< "$first"; then
        fail "$file is not exactly 40 hex digits and a newline"
    fi
}

check_public_key() {
    local key
    if ! key="$(distribution_value "$ROOT" RFM_SPARKLE_PUBLIC_KEY 2> /dev/null)"; then
        fail "RFM_SPARKLE_PUBLIC_KEY is missing or defined twice in Config/Distribution.xcconfig"
    elif [[ -z "$key" ]]; then
        fail "RFM_SPARKLE_PUBLIC_KEY is empty in Config/Distribution.xcconfig; create the key with scripts/make-update-keys.sh"
    fi
}

check_repository() {
    local expected
    if [[ "$VISIBILITY" != "PUBLIC" ]]; then
        fail "the repository is $VISIBILITY, not PUBLIC; anonymous downloads of the feed and the DMG need a public repository"
    fi
    if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
        if ! expected="$(distribution_value "$ROOT" RFM_REPOSITORY 2> /dev/null)"; then
            fail "RFM_REPOSITORY is missing or defined twice in Config/Distribution.xcconfig"
        elif [[ "$GITHUB_REPOSITORY" != "$expected" ]]; then
            fail "GITHUB_REPOSITORY is $GITHUB_REPOSITORY, but RFM_REPOSITORY is $expected; the feed URL names $expected"
        fi
    fi
}

# --- arguments -----------------------------------------------------------

dry_run=0
if [[ "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi
if [[ "${1:-}" == "--dry-run" ]]; then
    dry_run=1
    shift
fi
if [[ $# -ne 1 ]]; then
    usage_error "expected exactly one version"
fi
case "$1" in
    '') usage_error "the version is empty" ;;
    -*) usage_error "unknown option: $1" ;;
esac

if [[ "$dry_run" -eq 0 ]]; then
    [[ -n "${DEFAULT_BRANCH:-}" ]] || usage_error "DEFAULT_BRANCH is required in tag mode"
    [[ -n "${PUBLISHED_TAGS_FILE:-}" ]] || usage_error "PUBLISHED_TAGS_FILE is required in tag mode"
    [[ -n "${VISIBILITY:-}" ]] || usage_error "VISIBILITY is required in tag mode"
    [[ -f "$PUBLISHED_TAGS_FILE" ]] || usage_error "PUBLISHED_TAGS_FILE is not a file: $PUBLISHED_TAGS_FILE"
fi

# --- checks ----------------------------------------------------------------

release_ok=0
if [[ "$dry_run" -eq 1 ]]; then
    version="$1"
    tag="v$version"
    if is_release_version "$version"; then
        release_ok=1
    else
        fail "$version is not a release version: it must be X.Y.Z, with no leading v or zeros and no suffix, X up to 2000 and Y and Z up to 999"
    fi
    notice "dry run: the tag, branch, published, visibility and repository checks are skipped"
else
    tag="$1"
    version="${tag#v}"
    if is_release_tag "$tag"; then
        release_ok=1
    else
        fail "$tag is not a release tag: it must be vX.Y.Z, with no leading zeros and no suffix, X up to 2000 and Y and Z up to 999"
    fi
fi

# Nothing below can be checked for a name that is not a release version.
if [[ "$release_ok" -eq 1 ]]; then
    if [[ "$dry_run" -eq 0 ]]; then
        check_tag
    fi
    check_notes
fi
check_identity_file
check_public_key
if [[ "$dry_run" -eq 0 ]]; then
    check_repository
fi

if [[ "$failures" -gt 0 ]]; then
    printf 'preflight: %d check(s) failed\n' "$failures" >&2
    exit 1
fi

build_number="$(build_number_for "$version")"
strict_release=0
if [[ "${version%%.*}" -ge 1 ]]; then
    strict_release=1
fi
printf 'TAG=%s\n' "$tag"
printf 'VERSION=%s\n' "$version"
printf 'BUILD_NUMBER=%s\n' "$build_number"
printf 'ARCHIVE_NAME=RoomForMac-%s.tar.xz\n' "$version"
printf 'SOURCE_NAME=RoomForMac-%s-source.tar.gz\n' "$version"
printf 'STRICT_RELEASE=%s\n' "$strict_release"
printf 'DRY_RUN=%s\n' "$dry_run"
printf 'APP=%s\n' "$APP_PATH"
