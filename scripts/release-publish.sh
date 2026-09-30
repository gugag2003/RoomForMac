#!/bin/bash
# The checks release.yml runs around the GitHub release, in one script so that
# bats can test them (the workflow's run blocks stay thin).
#
#   release-publish.sh check-files <dir> <X.Y.Z>
#       <dir> holds exactly the six release files, none of them empty, and they
#       agree with one another: SHA256SUMS verifies, appcast.xml has this
#       build's item and points at this tag's archive, latest.json names this
#       version. The build job runs it before uploading the files and the
#       publish job after downloading them, so a dry run applies it too.
#   release-publish.sh replace-draft <vX.Y.Z>
#       deletes a leftover draft release for the tag, so a rerun starts clean.
#       It refuses a tag that already has a published release, and then deletes
#       nothing: a published release is never touched.
#   release-publish.sh check-feed <build-number> [--attempts N] [--interval SECONDS]
#       waits (default: 11 attempts, 30 s apart, so five minutes) until the feed
#       in Config/Distribution.xcconfig serves that build and the download URL
#       answers 200.
#
# Tools: GH (gh), CURL (curl) and SLEEP (sleep), so that bats can stub them.
# It runs on macOS and on ubuntu-latest, so it uses only portable tools.
# Exit status: 0 done; 1 a check failed; 2 usage error.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GH="${GH:-gh}"
CURL="${CURL:-curl}"
SLEEP="${SLEEP:-sleep}"

# shellcheck source=lib/distribution.sh
source "$ROOT/scripts/lib/distribution.sh"
# shellcheck source=lib/version.sh
source "$ROOT/scripts/lib/version.sh"

usage() {
    cat >&2 << 'EOF'
usage: release-publish.sh check-files <dir> <X.Y.Z>
       release-publish.sh replace-draft <vX.Y.Z>
       release-publish.sh check-feed <build-number> [--attempts N] [--interval SECONDS]
EOF
    exit 2
}

usage_error() {
    printf 'error: %s\n' "$*" >&2
    exit 2
}

problems=0
problem() {
    printf 'error: %s\n' "$*" >&2
    problems=$((problems + 1))
}

# sha256sum on ubuntu, shasum on macOS; both read `<hash>  <name>` lines.
sha256_check() {
    if command -v sha256sum > /dev/null 2>&1; then
        sha256sum -c "$1"
    else
        shasum -a 256 -c "$1"
    fi
}

check_files() {
    local dir="$1" version="$2" build update_archive source_archive name listed wanted
    [[ -d "$dir" ]] || usage_error "$dir is not a folder"
    version_is_release "$version" || usage_error "$version is not a release version (X.Y.Z)"
    build="$(build_number_for "$version")"
    update_archive="RoomForMac-$version.tar.xz"
    source_archive="RoomForMac-$version-source.tar.gz"
    local expected=(RoomForMac.dmg "$update_archive" "$source_archive" appcast.xml latest.json SHA256SUMS)

    for name in "${expected[@]}"; do
        if [[ ! -f "$dir/$name" || -L "$dir/$name" ]]; then
            problem "$name is missing from $dir"
        elif [[ ! -s "$dir/$name" ]]; then
            problem "$name is empty"
        fi
    done
    while IFS= read -r name; do
        if ! printf '%s\n' "${expected[@]}" | grep -Fxq -- "$name"; then
            problem "unexpected file $name in $dir"
        fi
    done < <(ls -A "$dir")

    if [[ -s "$dir/SHA256SUMS" ]]; then
        listed="$(awk '{ sub(/^[^ ]+ +\*?/, ""); print }' "$dir/SHA256SUMS" | LC_ALL=C sort | tr '\n' ' ')"
        wanted="$(printf '%s\n' RoomForMac.dmg "$update_archive" "$source_archive" | LC_ALL=C sort | tr '\n' ' ')"
        if [[ "$listed" != "$wanted" ]]; then
            problem "SHA256SUMS lists ${listed% } instead of ${wanted% }"
        elif ! (cd "$dir" && sha256_check SHA256SUMS > /dev/null 2>&1); then
            problem "SHA256SUMS does not match the files in $dir"
        fi
    fi
    if [[ -s "$dir/appcast.xml" ]]; then
        grep -Eq "<sparkle:version>[[:space:]]*${build}[[:space:]]*</sparkle:version>" "$dir/appcast.xml" ||
            problem "appcast.xml has no item for build $build"
        grep -Fq "/releases/download/v$version/$update_archive" "$dir/appcast.xml" ||
            problem "appcast.xml does not point at v$version/$update_archive"
    fi
    if [[ -s "$dir/latest.json" ]]; then
        grep -Eq "\"version\"[[:space:]]*:[[:space:]]*\"${version//./\\.}\"" "$dir/latest.json" ||
            problem "latest.json does not name version $version"
    fi

    if [[ $problems -gt 0 ]]; then
        exit 1
    fi
    printf 'ok: %s holds the six release files for %s (build %s)\n' "$dir" "$version" "$build"
}

replace_draft() {
    local tag="$1" listing entry_tag id draft published=0
    local drafts=()
    if [[ "$tag" != v* ]] || ! version_is_release "${tag#v}"; then
        usage_error "$tag is not a release tag (vX.Y.Z)"
    fi
    # One "<tag> <id> <draft>" line per release; a draft carries the tag name it
    # was created with. gh expands {owner} and {repo} from GH_REPO or the checkout.
    listing="$("$GH" api "repos/{owner}/{repo}/releases" --paginate \
        --jq '.[] | "\(.tag_name) \(.id) \(.draft)"')"
    while read -r entry_tag id draft; do
        if [[ "$entry_tag" != "$tag" ]]; then
            continue
        fi
        if [[ "$draft" == true ]]; then
            drafts+=("$id")
        else
            published=1
        fi
    done <<< "$listing"

    if [[ $published -eq 1 ]]; then
        printf 'error: %s already has a published release. A published release is never replaced: publish a higher version instead.\n' "$tag" >&2
        exit 1
    fi
    if [[ ${#drafts[@]} -eq 0 ]]; then
        printf 'no leftover draft for %s\n' "$tag"
        return 0
    fi
    for id in "${drafts[@]}"; do
        "$GH" api --method DELETE "repos/{owner}/{repo}/releases/$id" > /dev/null
        printf 'deleted the leftover draft %s for %s\n' "$id" "$tag"
    done
}

check_feed() {
    local build="$1" attempts="$2" interval="$3" attempt feed repository download body code
    feed="$(distribution_value "$ROOT" RFM_FEED_URL)"
    repository="$(distribution_value "$ROOT" RFM_REPOSITORY)"
    download="https://github.com/$repository/releases/latest/download/RoomForMac.dmg"
    code=""
    for ((attempt = 1; attempt <= attempts; attempt++)); do
        body="$("$CURL" -fsSL --max-time 30 "$feed" 2> /dev/null || true)"
        code="$("$CURL" -sSIL --max-time 30 -o /dev/null -w '%{http_code}' "$download" 2> /dev/null || true)"
        if grep -Eq "<sparkle:version>[[:space:]]*${build}[[:space:]]*</sparkle:version>" <<< "$body" &&
            [[ "$code" == 200 ]]; then
            printf 'ok: %s serves build %s and %s answers 200 (attempt %s of %s)\n' "$feed" "$build" "$download" "$attempt" "$attempts"
            return 0
        fi
        printf 'attempt %s of %s: %s does not serve build %s yet, or the download answers %s\n' \
            "$attempt" "$attempts" "$feed" "$build" "${code:-nothing}" >&2
        if [[ $attempt -lt $attempts ]]; then
            "$SLEEP" "$interval"
        fi
    done
    printf 'error: after %s attempts %s still does not serve build %s, or %s does not answer 200 (last answer: %s). The release is published; check the feed by hand (docs/releasing.md).\n' \
        "$attempts" "$feed" "$build" "$download" "${code:-nothing}" >&2
    return 1
}

if [[ $# -lt 1 ]]; then
    usage
fi
command="$1"
shift
case "$command" in
    check-files)
        [[ $# -eq 2 ]] || usage
        check_files "$1" "$2"
        ;;
    replace-draft)
        [[ $# -eq 1 ]] || usage
        replace_draft "$1"
        ;;
    check-feed)
        [[ $# -ge 1 ]] || usage
        build="$1"
        shift
        attempts=11
        interval=30
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --attempts | --interval)
                    [[ $# -ge 2 ]] || usage_error "$1 needs a value"
                    if [[ "$1" == --attempts ]]; then
                        attempts="$2"
                    else
                        interval="$2"
                    fi
                    shift 2
                    ;;
                *) usage ;;
            esac
        done
        [[ "$build" =~ ^[0-9]+$ ]] || usage_error "the build number must be digits, not $build"
        [[ "$attempts" =~ ^[1-9][0-9]*$ ]] || usage_error "--attempts must be a whole number of at least 1"
        [[ "$interval" =~ ^[0-9]+$ ]] || usage_error "--interval must be a whole number of seconds"
        check_feed "$build" "$attempts" "$interval"
        ;;
    *) usage ;;
esac
