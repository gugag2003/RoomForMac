#!/usr/bin/env bats
# Checks scripts/release-publish.sh, the release workflow's checks around the
# GitHub release. Each test runs a copy of the script inside a throwaway tree
# that has its own Config/Distribution.xcconfig, with stub executables on the
# GH, CURL and SLEEP variables: nothing here talks to GitHub, and nothing waits.
# The stubs log their arguments to $STATE. The replace-draft tests answer the
# release listing through jq (macOS ships /usr/bin/jq) and skip without it.

setup_file() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    STUBS="$BATS_FILE_TMPDIR/stubs"
    mkdir -p "$STUBS"

    cat > "$STUBS/gh" << 'STUB'
#!/bin/bash
# gh(1) stand-in for the two `gh api` calls the script makes. The listing is
# $STATE/releases.json, filtered with the script's own --jq expression; a
# DELETE is only logged.
set -euo pipefail
printf '%s\n' "$*" >> "$STATE/gh.log"
if [[ "$1" == api && "$2" == "repos/{owner}/{repo}/releases" ]]; then
    filter=""
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == --jq ]]; then
            filter="$2"
        fi
        shift
    done
    jq -r "$filter" "$STATE/releases.json"
elif [[ "$1 $2 $3" == "api --method DELETE" ]]; then
    exit 0
else
    echo "stub gh: unexpected arguments: $*" >&2
    exit 64
fi
STUB

    cat > "$STUBS/curl" << 'STUB'
#!/bin/bash
# curl(1) stand-in. The feed answers $STATE/feed-old.xml until its
# $STUB_FEED_READY_AT-th request and $STATE/feed-new.xml from then on (or fails
# like `curl -f` on a 404 when STUB_FEED_FAIL=1). A HEAD request for the DMG
# prints $STUB_DMG_CODE, as `-w '%{http_code}'` would.
set -euo pipefail
printf '%s\n' "$*" >> "$STATE/curl.log"
url="${!#}"
case "$url" in
    */appcast.xml)
        calls=$(($(cat "$STATE/feed-calls" 2> /dev/null || echo 0) + 1))
        echo "$calls" > "$STATE/feed-calls"
        if [[ "${STUB_FEED_FAIL:-0}" == 1 ]]; then
            exit 22
        fi
        if [[ "$calls" -ge "${STUB_FEED_READY_AT:-1}" ]]; then
            cat "$STATE/feed-new.xml"
        else
            cat "$STATE/feed-old.xml"
        fi
        ;;
    */RoomForMac.dmg)
        printf '%s' "${STUB_DMG_CODE:-200}"
        ;;
    *)
        echo "stub curl: unexpected URL: $url" >&2
        exit 64
        ;;
esac
STUB

    cat > "$STUBS/sleep" << 'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$STATE/sleep.log"
STUB
    chmod +x "$STUBS/gh" "$STUBS/curl" "$STUBS/sleep"
    export ROOT STUBS
}

setup() {
    TREE="$BATS_TEST_TMPDIR/tree"
    STATE="$BATS_TEST_TMPDIR/state"
    mkdir -p "$TREE/scripts/lib" "$TREE/Config" "$STATE"
    cp "$ROOT/scripts/release-publish.sh" "$TREE/scripts/"
    cp "$ROOT/scripts/lib/distribution.sh" "$ROOT/scripts/lib/version.sh" "$TREE/scripts/lib/"
    cat > "$TREE/Config/Distribution.xcconfig" << 'XCCONFIG'
RFM_REPOSITORY = example/Widget
RFM_FEED_URL = https:/$()/github.com/example/Widget/releases/latest/download/appcast.xml
XCCONFIG
    SCRIPT="$TREE/scripts/release-publish.sh"
    export STATE GH="$STUBS/gh" CURL="$STUBS/curl" SLEEP="$STUBS/sleep"
}

# The six files of release 1.2.3 (build 1002003), consistent with one another.
make_release_dir() {
    local dir="$1"
    mkdir -p "$dir"
    printf 'dmg\n' > "$dir/RoomForMac.dmg"
    printf 'update archive\n' > "$dir/RoomForMac-1.2.3.tar.xz"
    printf 'source archive\n' > "$dir/RoomForMac-1.2.3-source.tar.gz"
    cat > "$dir/appcast.xml" << 'XML'
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel>
<item>
<sparkle:version>1002003</sparkle:version>
<sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>
<enclosure url="https://github.com/example/Widget/releases/download/v1.2.3/RoomForMac-1.2.3.tar.xz" length="15" type="application/x-xz"/>
</item>
</channel></rss>
XML
    printf '{"schema":1,"version":"1.2.3","build":1002003}\n' > "$dir/latest.json"
    (cd "$dir" && shasum -a 256 RoomForMac.dmg RoomForMac-1.2.3.tar.xz RoomForMac-1.2.3-source.tar.gz > SHA256SUMS)
}

# edit_file <file> <sed expression>: rewrites the file in place, without sed -i.
edit_file() {
    sed "$2" "$1" > "$1.new"
    mv "$1.new" "$1"
}

# expect_problem <fragment>: check-files on the test's folder exits 1 and names the fragment.
expect_problem() {
    run "$SCRIPT" check-files "$BATS_TEST_TMPDIR/out" 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"$1"* ]]
}

@test "check-files accepts the six consistent files" {
    make_release_dir "$BATS_TEST_TMPDIR/out"
    run "$SCRIPT" check-files "$BATS_TEST_TMPDIR/out" 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *"holds the six release files for 1.2.3 (build 1002003)"* ]]
}

@test "check-files names a missing file" {
    make_release_dir "$BATS_TEST_TMPDIR/out"
    rm "$BATS_TEST_TMPDIR/out/RoomForMac-1.2.3-source.tar.gz"
    expect_problem "RoomForMac-1.2.3-source.tar.gz is missing"
}

@test "check-files names an empty file" {
    make_release_dir "$BATS_TEST_TMPDIR/out"
    : > "$BATS_TEST_TMPDIR/out/latest.json"
    expect_problem "latest.json is empty"
}

@test "check-files refuses a symlink in place of a file" {
    make_release_dir "$BATS_TEST_TMPDIR/out"
    mv "$BATS_TEST_TMPDIR/out/appcast.xml" "$BATS_TEST_TMPDIR/elsewhere.xml"
    ln -s "$BATS_TEST_TMPDIR/elsewhere.xml" "$BATS_TEST_TMPDIR/out/appcast.xml"
    expect_problem "appcast.xml is missing"
}

@test "check-files refuses a file that does not belong" {
    make_release_dir "$BATS_TEST_TMPDIR/out"
    printf 'x\n' > "$BATS_TEST_TMPDIR/out/notes.txt"
    expect_problem "unexpected file notes.txt"
}

@test "check-files catches a file changed after the sums were written" {
    make_release_dir "$BATS_TEST_TMPDIR/out"
    printf 'tampered\n' >> "$BATS_TEST_TMPDIR/out/RoomForMac.dmg"
    expect_problem "SHA256SUMS does not match the files"
}

@test "check-files catches sums that leave a file out" {
    make_release_dir "$BATS_TEST_TMPDIR/out"
    (cd "$BATS_TEST_TMPDIR/out" && shasum -a 256 RoomForMac.dmg RoomForMac-1.2.3.tar.xz > SHA256SUMS)
    expect_problem "SHA256SUMS lists RoomForMac-1.2.3.tar.xz RoomForMac.dmg instead of"
}

@test "check-files catches an appcast without this build's item" {
    make_release_dir "$BATS_TEST_TMPDIR/out"
    edit_file "$BATS_TEST_TMPDIR/out/appcast.xml" 's/<sparkle:version>1002003</<sparkle:version>1002002</'
    expect_problem "appcast.xml has no item for build 1002003"
}

@test "check-files catches an appcast that points at another tag" {
    make_release_dir "$BATS_TEST_TMPDIR/out"
    edit_file "$BATS_TEST_TMPDIR/out/appcast.xml" 's#download/v1.2.3/#download/v1.2.2/#'
    expect_problem "appcast.xml does not point at v1.2.3/RoomForMac-1.2.3.tar.xz"
}

@test "check-files catches a summary for another version" {
    make_release_dir "$BATS_TEST_TMPDIR/out"
    printf '{"schema":1,"version":"1.2.2","build":1002002}\n' > "$BATS_TEST_TMPDIR/out/latest.json"
    expect_problem "latest.json does not name version 1.2.3"
}

@test "check-files reports every problem, not only the first" {
    make_release_dir "$BATS_TEST_TMPDIR/out"
    rm "$BATS_TEST_TMPDIR/out/RoomForMac.dmg"
    : > "$BATS_TEST_TMPDIR/out/latest.json"
    run "$SCRIPT" check-files "$BATS_TEST_TMPDIR/out" 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"RoomForMac.dmg is missing"* ]] || return 1
    [[ "$output" == *"latest.json is empty"* ]]
}

@test "check-files gives a usage error for a bad folder, version or argument list" {
    make_release_dir "$BATS_TEST_TMPDIR/out"
    run "$SCRIPT" check-files "$BATS_TEST_TMPDIR/nowhere" 1.2.3
    [ "$status" -eq 2 ]
    run "$SCRIPT" check-files "$BATS_TEST_TMPDIR/out" 1.2
    [ "$status" -eq 2 ]
    run "$SCRIPT" check-files "$BATS_TEST_TMPDIR/out"
    [ "$status" -eq 2 ]
    run "$SCRIPT"
    [ "$status" -eq 2 ]
    run "$SCRIPT" frobnicate
    [ "$status" -eq 2 ]
}

# gh_deletes: the DELETE calls the stub gh logged, one per line ("" when none).
gh_deletes() {
    grep DELETE "$STATE/gh.log" || true
}

@test "replace-draft deletes every draft of the tag and nothing else" {
    command -v jq > /dev/null 2>&1 || skip "jq is required"
    cat > "$STATE/releases.json" << 'JSON'
[
  {"tag_name": "v1.2.3", "id": 11, "draft": true},
  {"tag_name": "v1.2.3", "id": 12, "draft": true},
  {"tag_name": "v1.2.4", "id": 13, "draft": true},
  {"tag_name": "v1.2.2", "id": 10, "draft": false}
]
JSON
    run "$SCRIPT" replace-draft v1.2.3
    [ "$status" -eq 0 ]
    [ "$(gh_deletes)" = $'api --method DELETE repos/{owner}/{repo}/releases/11\napi --method DELETE repos/{owner}/{repo}/releases/12' ]
}

@test "replace-draft does nothing when the tag has no release" {
    command -v jq > /dev/null 2>&1 || skip "jq is required"
    cat > "$STATE/releases.json" << 'JSON'
[
  {"tag_name": "v1.2.2", "id": 10, "draft": false},
  {"tag_name": "v1.2.4", "id": 13, "draft": true}
]
JSON
    run "$SCRIPT" replace-draft v1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *"no leftover draft for v1.2.3"* ]] || return 1
    [ -z "$(gh_deletes)" ]
}

@test "replace-draft refuses a published release and deletes nothing, drafts included" {
    command -v jq > /dev/null 2>&1 || skip "jq is required"
    cat > "$STATE/releases.json" << 'JSON'
[
  {"tag_name": "v1.2.3", "id": 11, "draft": true},
  {"tag_name": "v1.2.3", "id": 9, "draft": false}
]
JSON
    run "$SCRIPT" replace-draft v1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"v1.2.3 already has a published release"* ]] || return 1
    [ -z "$(gh_deletes)" ]
}

@test "replace-draft gives a usage error for anything but a release tag" {
    run "$SCRIPT" replace-draft 1.2.3
    [ "$status" -eq 2 ]
    run "$SCRIPT" replace-draft v1.2
    [ "$status" -eq 2 ]
    run "$SCRIPT" replace-draft
    [ "$status" -eq 2 ]
    [ ! -e "$STATE/gh.log" ]
}

# A feed that lists the previous build, and one that also lists this one (1002003).
# The old feed also holds 10020031, which must not count as build 1002003.
make_feeds() {
    cat > "$STATE/feed-old.xml" << 'XML'
<rss><channel><item><sparkle:version>1002002</sparkle:version></item><item><sparkle:version>10020031</sparkle:version></item></channel></rss>
XML
    cat > "$STATE/feed-new.xml" << 'XML'
<rss><channel><item><sparkle:version>1002003</sparkle:version></item><item><sparkle:version>1002002</sparkle:version></item></channel></rss>
XML
}

@test "check-feed passes at once when the feed and the download are live" {
    make_feeds
    run "$SCRIPT" check-feed 1002003
    [ "$status" -eq 0 ]
    [[ "$output" == *"serves build 1002003"* ]] || return 1
    [ ! -e "$STATE/sleep.log" ]
}

@test "check-feed reads the feed and the download URL from Config" {
    make_feeds
    run "$SCRIPT" check-feed 1002003
    [ "$status" -eq 0 ]
    grep -qx -- '-fsSL --max-time 30 https://github.com/example/Widget/releases/latest/download/appcast.xml' "$STATE/curl.log"
    grep -qx -- '-sSIL --max-time 30 -o /dev/null -w %{http_code} https://github.com/example/Widget/releases/latest/download/RoomForMac.dmg' "$STATE/curl.log"
}

@test "check-feed retries every interval until the new build shows up" {
    make_feeds
    export STUB_FEED_READY_AT=3
    run "$SCRIPT" check-feed 1002003
    [ "$status" -eq 0 ]
    [[ "$output" == *"(attempt 3 of 11)"* ]] || return 1
    [ "$(cat "$STATE/sleep.log")" = $'30\n30' ]
}

@test "check-feed fails after its attempts when only older builds are served" {
    make_feeds
    export STUB_FEED_READY_AT=99
    run "$SCRIPT" check-feed 1002003 --attempts 4 --interval 5
    [ "$status" -eq 1 ]
    [[ "$output" == *"after 4 attempts"* ]] || return 1
    [ "$(cat "$STATE/feed-calls")" = 4 ] || return 1
    [ "$(cat "$STATE/sleep.log")" = $'5\n5\n5' ]
}

@test "check-feed fails when the download URL does not answer 200" {
    make_feeds
    export STUB_DMG_CODE=404
    run "$SCRIPT" check-feed 1002003 --attempts 2 --interval 1
    [ "$status" -eq 1 ]
    [[ "$output" == *"the download answers 404"* ]] || return 1
    [[ "$output" == *"last answer: 404"* ]]
}

@test "check-feed treats an unreachable feed as not ready yet" {
    make_feeds
    export STUB_FEED_FAIL=1
    run "$SCRIPT" check-feed 1002003 --attempts 2 --interval 1
    [ "$status" -eq 1 ]
    [[ "$output" == *"after 2 attempts"* ]]
}

@test "check-feed gives a usage error for a bad build number or option" {
    run "$SCRIPT" check-feed v1002003
    [ "$status" -eq 2 ]
    run "$SCRIPT" check-feed 1002003 --attempts 0
    [ "$status" -eq 2 ]
    run "$SCRIPT" check-feed 1002003 --interval soon
    [ "$status" -eq 2 ]
    run "$SCRIPT" check-feed 1002003 --attempts
    [ "$status" -eq 2 ]
    run "$SCRIPT" check-feed 1002003 --frobnicate
    [ "$status" -eq 2 ]
    run "$SCRIPT" check-feed
    [ "$status" -eq 2 ]
    [ ! -e "$STATE/curl.log" ]
}
