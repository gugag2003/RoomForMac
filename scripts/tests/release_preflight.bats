#!/usr/bin/env bats
# Checks scripts/release-preflight.sh, scripts/release-hook.sh and the
# release-notes files. Every test runs copies of the scripts inside a throwaway
# git repository whose "origin" is a bare repository next to it, with HOME in
# the test folder. Nothing reaches the network, GitHub, the real home or this
# repository's git state. The tests only read this repository's scripts/lib/
# and release-notes/, and, in the last test, scripts/release-hooks/.
#
# The repository starts at one release, v0.1.0 (its notes are the template with
# the placeholder lines replaced), pushed to origin; a test then breaks exactly
# one thing and checks that exactly that check fails.

FINGERPRINT=1A2B3C4D5E6F708192A3B4C5D6E7F8091A2B3C4D
SENTENCE="RoomForMac is free software under the GNU General Public License, version 3."

# git_environment HOME: git without any configuration of the person running the
# tests (a signing key, a template directory, a default branch name).
git_environment() {
    export HOME="$1"
    export GIT_CONFIG_NOSYSTEM=1
    export GIT_AUTHOR_NAME=Tester GIT_AUTHOR_EMAIL=tester@example.invalid
    export GIT_COMMITTER_NAME=Tester GIT_COMMITTER_EMAIL=tester@example.invalid
    mkdir -p "$HOME"
}

# Building a repository takes about half a second, so every test starts from a
# copy of one seed instead: the scripts, the fixture files and one release,
# v0.1.0, pushed to a bare origin next to it.
setup_file() {
    SEED="$BATS_FILE_TMPDIR/seed"
    REPO="$SEED/repo"
    ORIGIN="$SEED/origin.git"
    TEMPLATE="$BATS_TEST_DIRNAME/../../release-notes/TEMPLATE.md"
    export SEED
    git_environment "$SEED/home"
    mkdir -p "$REPO/scripts/lib" "$REPO/scripts/release-hooks" "$REPO/Config" "$REPO/release-notes"
    cp "$BATS_TEST_DIRNAME/../release-preflight.sh" "$BATS_TEST_DIRNAME/../release-hook.sh" "$REPO/scripts/"
    cp "$BATS_TEST_DIRNAME/../lib/distribution.sh" "$BATS_TEST_DIRNAME/../lib/version.sh" "$REPO/scripts/lib/"
    cp "$TEMPLATE" "$REPO/release-notes/TEMPLATE.md"
    cat > "$REPO/Config/Distribution.xcconfig" << 'XCCONFIG'
// A fixture with the shape of the real file.
RFM_REPOSITORY = gugag2003/RoomForMac
RFM_FEED_URL = https:/$()/github.com/gugag2003/RoomForMac/releases/latest/download/appcast.xml
RFM_SITE_URL = https:/$()/gugag2003.github.io/RoomForMac
RFM_DMG_VOLUME_NAME = RoomForMac
RFM_SPARKLE_PUBLIC_KEY = dGVzdC1rZXktbm90LWEtcmVhbC1lZDI1NTE5LWtleQ==
XCCONFIG
    printf '%s\n' "$FINGERPRINT" > "$REPO/Config/signing-identity.sha1"
    git init --quiet --bare "$ORIGIN"
    git init --quiet "$REPO"
    git_repo symbolic-ref HEAD refs/heads/main
    git_repo remote add origin "$ORIGIN"
    release_version 0.1.0
}

setup() {
    TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
    REPO="$TMP/repo"
    ORIGIN="$TMP/origin.git"
    PUBLISHED="$TMP/published-tags.txt"
    OUT="$TMP/stdout"
    ERR="$TMP/stderr"
    SCRIPT="$REPO/scripts/release-preflight.sh"
    HOOK="$REPO/scripts/release-hook.sh"
    TEMPLATE="$BATS_TEST_DIRNAME/../../release-notes/TEMPLATE.md"
    DEFAULT_BRANCH=main
    PUBLISHED_TAGS_FILE="$PUBLISHED"
    VISIBILITY=PUBLIC
    GITHUB_REPOSITORY=
    export DEFAULT_BRANCH PUBLISHED_TAGS_FILE VISIBILITY GITHUB_REPOSITORY
    git_environment "$TMP/home"
    : > "$PUBLISHED"
    cp -R "$SEED/repo" "$REPO"
    cp -R "$SEED/origin.git" "$ORIGIN"
    git_repo remote set-url origin "$ORIGIN"
}

git_repo() {
    git -C "$REPO" "$@"
}

# write_notes X.Y.Z: the template with its placeholder lines replaced, as an
# author would write it.
write_notes() {
    sed 's/^- Replace this line.*$/- A real note./' "$TEMPLATE" > "$REPO/release-notes/$1.md"
}

# tag_release X.Y.Z: notes, a commit and an annotated tag on the current branch.
tag_release() {
    write_notes "$1"
    git_repo add -A
    git_repo commit --quiet -m "Release $1"
    git_repo tag -a "v$1" -m "RoomForMac $1"
}

# release_version X.Y.Z: tag_release, pushed to origin with the branch.
release_version() {
    tag_release "$1"
    git_repo push --quiet origin main "v$1"
}

# preflight ARGS...: runs the script from outside the repository, keeping
# stdout in $OUT, stderr in $ERR and the exit status in $status.
preflight() {
    status=0
    (cd "$TMP" && "$SCRIPT" "$@") > "$OUT" 2> "$ERR" || status=$?
}

error_count() {
    grep -c '^::error::' "$ERR" || true
}

# failed_alone TEXT: exit 1, exactly one ::error:: line, that line contains TEXT,
# and stdout stays empty, so `>> $GITHUB_ENV` receives nothing.
failed_alone() {
    [ "$status" -eq 1 ]
    [ "$(error_count)" -eq 1 ]
    awk -v text="$1" 'index($0, "::error::") == 1 && index($0, text) > 0 { found = 1 } END { exit !found }' "$ERR"
    [ ! -s "$OUT" ]
}

set_public_key() {
    grep -v '^RFM_SPARKLE_PUBLIC_KEY' "$REPO/Config/Distribution.xcconfig" > "$TMP/xcconfig"
    if [ "$#" -gt 0 ]; then
        printf 'RFM_SPARKLE_PUBLIC_KEY = %s\n' "$1" >> "$TMP/xcconfig"
    fi
    mv "$TMP/xcconfig" "$REPO/Config/Distribution.xcconfig"
}

@test "a good tag prints exactly the KEY=VALUE set and nothing on stderr" {
    local expected
    expected="$(printf '%s\n' TAG=v0.1.0 VERSION=0.1.0 BUILD_NUMBER=1000 \
        ARCHIVE_NAME=RoomForMac-0.1.0.tar.xz SOURCE_NAME=RoomForMac-0.1.0-source.tar.gz \
        STRICT_RELEASE=0 DRY_RUN=0 APP=build/DerivedData/Build/Products/Release/RoomForMac.app)"
    preflight v0.1.0
    [ "$status" -eq 0 ]
    [ "$(cat "$OUT")" = "$expected" ]
    [ ! -s "$ERR" ]
}

@test "the build number follows the tag, and STRICT_RELEASE is 1 from 1.0.0 on" {
    local row version build strict
    for row in "0.9.9 9009 0" "1.0.0 1000000 1" "1.2.3 1002003 1"; do
        read -r version build strict <<< "$row"
        release_version "$version"
        preflight "v$version"
        [ "$status" -eq 0 ]
        grep -qx "VERSION=$version" "$OUT"
        grep -qx "BUILD_NUMBER=$build" "$OUT"
        grep -qx "STRICT_RELEASE=$strict" "$OUT"
        grep -qx "ARCHIVE_NAME=RoomForMac-$version.tar.xz" "$OUT"
        grep -qx "SOURCE_NAME=RoomForMac-$version-source.tar.gz" "$OUT"
    done
}

@test "the script does not depend on the working directory" {
    status=0
    (cd / && "$SCRIPT" v0.1.0) > "$OUT" 2> "$ERR" || status=$?
    [ "$status" -eq 0 ]
    grep -qx 'TAG=v0.1.0' "$OUT"
}

@test "a name that is not a strict release tag fails that check alone" {
    local name
    for name in v1.2 v1.2.3-beta v01.2.3 1.2.3 v2001.0.0 V1.2.3 v; do
        preflight "$name"
        failed_alone "is not a release tag"
    done
}

@test "a tag that does not exist fails that check alone" {
    write_notes 0.1.1
    preflight v0.1.1
    failed_alone "tag v0.1.1 does not exist"
}

@test "a checkout that is not at the tag fails that check alone" {
    printf 'later\n' > "$REPO/later.txt"
    git_repo add -A
    git_repo commit --quiet -m "A later commit"
    git_repo push --quiet origin main
    preflight v0.1.0
    failed_alone "HEAD is not the commit of v0.1.0"
}

@test "a tag that is not on the default branch fails that check alone" {
    git_repo checkout --quiet -b side
    tag_release 0.2.0
    git_repo push --quiet origin v0.2.0
    preflight v0.2.0
    failed_alone "v0.2.0 is not on origin/main"
}

@test "an unknown default branch fails that check alone" {
    DEFAULT_BRANCH=develop
    preflight v0.1.0
    failed_alone "origin/develop was not found"
}

@test "a newer tag in the repository fails that check alone" {
    release_version 0.3.0
    git_repo checkout --quiet --detach v0.1.0
    preflight v0.1.0
    failed_alone "v0.3.0 is newer than v0.1.0"
}

@test "tags are ordered by version, not as text" {
    release_version 0.9.0
    release_version 0.10.0
    preflight v0.10.0
    [ "$status" -eq 0 ]
    git_repo checkout --quiet --detach v0.9.0
    preflight v0.9.0
    failed_alone "v0.10.0 is newer than v0.9.0"
}

@test "tags that are not strict release tags never count as newer" {
    git_repo tag v9.9.9-beta
    git_repo tag nightly
    git_repo tag v10
    git_repo tag vfoo
    preflight v0.1.0
    [ "$status" -eq 0 ]
}

@test "a tag that is already published fails that check alone" {
    printf 'v0.0.9\nv0.1.0\n' > "$PUBLISHED"
    preflight v0.1.0
    failed_alone "v0.1.0 is already published"
}

@test "a published tag that is newer fails that check alone" {
    printf 'v0.0.9\nv0.2.0\n' > "$PUBLISHED"
    preflight v0.1.0
    failed_alone "v0.2.0 is already published and is newer than v0.1.0"
}

@test "published tags are ordered by version, and lines that are not release tags are ignored" {
    release_version 0.10.0
    printf 'v0.9.0\n\nnightly\nv0.10.0-beta\nv0.1.0' > "$PUBLISHED"
    preflight v0.10.0
    [ "$status" -eq 0 ]
}

@test "release notes that are missing fail that check alone" {
    rm "$REPO/release-notes/0.1.0.md"
    preflight v0.1.0
    failed_alone "release-notes/0.1.0.md is missing"
}

@test "release notes that are empty or only white space fail that check alone" {
    : > "$REPO/release-notes/0.1.0.md"
    preflight v0.1.0
    failed_alone "release-notes/0.1.0.md is empty"
    printf ' \n\n\t\n' > "$REPO/release-notes/0.1.0.md"
    preflight v0.1.0
    failed_alone "release-notes/0.1.0.md is empty"
}

@test "release notes with a TODO fail that check alone" {
    printf 'TODO: say what changed\n' >> "$REPO/release-notes/0.1.0.md"
    preflight v0.1.0
    failed_alone "release-notes/0.1.0.md contains TODO"
}

@test "release notes without the closing licence paragraph fail that check alone" {
    printf "## What's new\n\n- A real note.\n" > "$REPO/release-notes/0.1.0.md"
    preflight v0.1.0
    failed_alone "release-notes/0.1.0.md does not contain the closing licence paragraph"
}

@test "the closing paragraph may be wrapped anywhere" {
    printf '%s\n' "## What's new" "" "- A real note." "" \
        "RoomForMac is free software under the" "GNU General Public   License," "version 3. The rest follows." \
        > "$REPO/release-notes/0.1.0.md"
    preflight v0.1.0
    [ "$status" -eq 0 ]
}

@test "release notes that are still the template fail that check alone" {
    cp "$TEMPLATE" "$REPO/release-notes/0.1.0.md"
    preflight v0.1.0
    failed_alone "release-notes/0.1.0.md still contains the template's placeholder line"
}

@test "a missing fingerprint file fails that check alone" {
    rm "$REPO/Config/signing-identity.sha1"
    preflight v0.1.0
    failed_alone "Config/signing-identity.sha1 is missing"
}

@test "a fingerprint that is not 40 hex digits and a newline fails that check alone" {
    local content
    # printf %b turns \n and \r into the bytes: no newline at all, 39 and 41
    # digits, a non-hex digit, a leading space, CRLF, two lines, and a blank first line.
    for content in "$FINGERPRINT" "${FINGERPRINT:1}\n" "${FINGERPRINT}0\n" "Z${FINGERPRINT:1}\n" \
        " ${FINGERPRINT:1}\n" "${FINGERPRINT}\r\n" "${FINGERPRINT}\n${FINGERPRINT}\n" "\n${FINGERPRINT}" ""; do
        printf '%b' "$content" > "$REPO/Config/signing-identity.sha1"
        # The check is shared by both modes, and a dry run needs no git.
        preflight --dry-run 0.1.0
        failed_alone "Config/signing-identity.sha1 is not exactly 40 hex digits and a newline"
    done
    preflight v0.1.0
    failed_alone "Config/signing-identity.sha1 is not exactly 40 hex digits and a newline"
}

@test "a lower-case fingerprint is accepted" {
    printf '%s\n' "$(printf '%s' "$FINGERPRINT" | tr 'A-F' 'a-f')" > "$REPO/Config/signing-identity.sha1"
    preflight v0.1.0
    [ "$status" -eq 0 ]
}

@test "an empty Sparkle public key fails that check alone" {
    set_public_key ""
    preflight v0.1.0
    failed_alone "RFM_SPARKLE_PUBLIC_KEY is empty"
}

@test "a Sparkle public key that is missing or defined twice fails that check alone" {
    set_public_key
    preflight v0.1.0
    failed_alone "RFM_SPARKLE_PUBLIC_KEY is missing or defined twice"
    set_public_key "one"
    printf 'RFM_SPARKLE_PUBLIC_KEY = two\n' >> "$REPO/Config/Distribution.xcconfig"
    preflight v0.1.0
    failed_alone "RFM_SPARKLE_PUBLIC_KEY is missing or defined twice"
}

@test "a repository that is not PUBLIC fails that check alone" {
    local visibility
    for visibility in PRIVATE INTERNAL public; do
        VISIBILITY="$visibility"
        preflight v0.1.0
        failed_alone "the repository is $visibility, not PUBLIC"
    done
}

@test "GITHUB_REPOSITORY must equal RFM_REPOSITORY when it is set" {
    GITHUB_REPOSITORY=gugag2003/RoomForMac
    preflight v0.1.0
    [ "$status" -eq 0 ]
    GITHUB_REPOSITORY=someone/else
    preflight v0.1.0
    failed_alone "GITHUB_REPOSITORY is someone/else, but RFM_REPOSITORY is gugag2003/RoomForMac"
}

@test "every failed check is reported, not only the first" {
    rm "$REPO/Config/signing-identity.sha1"
    set_public_key ""
    VISIBILITY=PRIVATE
    GITHUB_REPOSITORY=someone/else
    printf 'v0.1.0\n' > "$PUBLISHED"
    preflight v0.1.0
    [ "$status" -eq 1 ]
    [ "$(error_count)" -eq 5 ]
    grep -q 'v0.1.0 is already published' "$ERR"
    grep -q 'Config/signing-identity.sha1 is missing' "$ERR"
    grep -q 'RFM_SPARKLE_PUBLIC_KEY is empty' "$ERR"
    grep -q 'the repository is PRIVATE' "$ERR"
    grep -q 'GITHUB_REPOSITORY is someone/else' "$ERR"
    grep -q 'preflight: 5 check(s) failed' "$ERR"
    [ ! -s "$OUT" ]
}

@test "--help prints the usage and exits 0" {
    preflight --help
    [ "$status" -eq 0 ]
    grep -qF 'Usage: scripts/release-preflight.sh <vX.Y.Z>' "$OUT"
    [ ! -s "$ERR" ]
}

@test "a wrong command line is a usage error" {
    preflight
    [ "$status" -eq 2 ]
    grep -qF 'error: expected exactly one version' "$ERR"
    preflight v0.1.0 v0.1.1
    [ "$status" -eq 2 ]
    preflight --bogus
    [ "$status" -eq 2 ]
    grep -qF 'error: unknown option: --bogus' "$ERR"
    preflight --dry-run
    [ "$status" -eq 2 ]
    preflight --dry-run --dry-run 0.1.0
    [ "$status" -eq 2 ]
    preflight ""
    [ "$status" -eq 2 ]
    grep -qF 'error: the version is empty' "$ERR"
    [ ! -s "$OUT" ]
}

@test "tag mode needs its environment, and the published-tags file must exist" {
    DEFAULT_BRANCH=
    preflight v0.1.0
    [ "$status" -eq 2 ]
    grep -qF 'error: DEFAULT_BRANCH is required in tag mode' "$ERR"
    DEFAULT_BRANCH=main
    PUBLISHED_TAGS_FILE=
    preflight v0.1.0
    [ "$status" -eq 2 ]
    grep -qF 'error: PUBLISHED_TAGS_FILE is required in tag mode' "$ERR"
    PUBLISHED_TAGS_FILE="$TMP/no-such-file"
    preflight v0.1.0
    [ "$status" -eq 2 ]
    grep -qF 'error: PUBLISHED_TAGS_FILE is not a file' "$ERR"
    PUBLISHED_TAGS_FILE="$PUBLISHED"
    VISIBILITY=
    preflight v0.1.0
    [ "$status" -eq 2 ]
    grep -qF 'error: VISIBILITY is required in tag mode' "$ERR"
    status=0
    (cd "$TMP" && env -u VISIBILITY "$SCRIPT" v0.1.0) > "$OUT" 2> "$ERR" || status=$?
    [ "$status" -eq 2 ]
    [ ! -s "$OUT" ]
}

@test "a tag with a newline cannot start a second workflow command" {
    preflight $'v0.1.0\n::warning::injected'
    [ "$status" -eq 1 ]
    [ "$(error_count)" -eq 1 ]
    [ -z "$(grep '^::warning::' "$ERR" || true)" ]
    [ ! -s "$OUT" ]
}

@test "a dry run skips the tag, branch, published, visibility and repository checks" {
    local expected
    expected="$(printf '%s\n' TAG=v0.1.0 VERSION=0.1.0 BUILD_NUMBER=1000 \
        ARCHIVE_NAME=RoomForMac-0.1.0.tar.xz SOURCE_NAME=RoomForMac-0.1.0-source.tar.gz \
        STRICT_RELEASE=0 DRY_RUN=1 APP=build/DerivedData/Build/Products/Release/RoomForMac.app)"
    # Each of these fails tag mode.
    git_repo tag -d v0.1.0
    DEFAULT_BRANCH=nowhere
    printf 'v0.1.0\nv0.2.0\n' > "$PUBLISHED"
    VISIBILITY=PRIVATE
    GITHUB_REPOSITORY=someone/else
    preflight v0.1.0
    [ "$status" -eq 1 ]
    preflight --dry-run 0.1.0
    [ "$status" -eq 0 ]
    [ "$(cat "$OUT")" = "$expected" ]
    grep -qF '::notice::dry run: the tag, branch, published, visibility and repository checks are skipped' "$ERR"
}

@test "a dry run needs none of the tag-mode environment" {
    status=0
    (cd "$TMP" && env -u DEFAULT_BRANCH -u PUBLISHED_TAGS_FILE -u VISIBILITY -u GITHUB_REPOSITORY \
        "$SCRIPT" --dry-run 0.1.0) > "$OUT" 2> "$ERR" || status=$?
    [ "$status" -eq 0 ]
    grep -qx 'DRY_RUN=1' "$OUT"
}

@test "a dry run still checks the notes, the fingerprint and the public key" {
    printf 'TODO\n' >> "$REPO/release-notes/0.1.0.md"
    preflight --dry-run 0.1.0
    failed_alone "release-notes/0.1.0.md contains TODO"
    write_notes 0.1.0
    rm "$REPO/Config/signing-identity.sha1"
    preflight --dry-run 0.1.0
    failed_alone "Config/signing-identity.sha1 is missing"
    printf '%s\n' "$FINGERPRINT" > "$REPO/Config/signing-identity.sha1"
    set_public_key ""
    preflight --dry-run 0.1.0
    failed_alone "RFM_SPARKLE_PUBLIC_KEY is empty"
}

@test "a dry run without notes for its version checks the template and says so" {
    rm "$REPO/release-notes/0.1.0.md"
    preflight --dry-run 0.1.0
    [ "$status" -eq 0 ]
    grep -qF '::notice::dry run: release-notes/0.1.0.md does not exist yet, so release-notes/TEMPLATE.md is checked instead' "$ERR"
    grep -qx 'VERSION=0.1.0' "$OUT"
}

@test "a dry run with notes for its version does not fall back to the template" {
    preflight --dry-run 0.1.0
    [ "$status" -eq 0 ]
    [ -z "$(grep 'checked instead' "$ERR" || true)" ]
    cp "$TEMPLATE" "$REPO/release-notes/0.1.0.md"
    preflight --dry-run 0.1.0
    failed_alone "release-notes/0.1.0.md still contains the template's placeholder line"
}

@test "a dry run refuses a template that lost the closing paragraph" {
    rm "$REPO/release-notes/0.1.0.md"
    printf "## What's new\n" > "$REPO/release-notes/TEMPLATE.md"
    preflight --dry-run 0.1.0
    failed_alone "release-notes/TEMPLATE.md does not contain the closing licence paragraph"
    rm "$REPO/release-notes/TEMPLATE.md"
    preflight --dry-run 0.1.0
    failed_alone "release-notes/TEMPLATE.md is missing"
}

@test "a dry run takes X.Y.Z, and STRICT_RELEASE is 1 from 1.0.0 on" {
    local name
    for name in v0.1.0 1.2 01.2.3 1.2.3-beta; do
        preflight --dry-run "$name"
        failed_alone "is not a release version"
    done
    write_notes 1.0.0
    preflight --dry-run 1.0.0
    [ "$status" -eq 0 ]
    grep -qx 'TAG=v1.0.0' "$OUT"
    grep -qx 'BUILD_NUMBER=1000000' "$OUT"
    grep -qx 'STRICT_RELEASE=1' "$OUT"
    grep -qx 'DRY_RUN=1' "$OUT"
}

@test "a version with a newline cannot start a second workflow command" {
    preflight --dry-run $'0.1.0\n::warning::injected'
    [ "$status" -eq 1 ]
    [ "$(error_count)" -eq 1 ]
    [ -z "$(grep '^::warning::' "$ERR" || true)" ]
    [ ! -s "$OUT" ]
}

@test "the template has both sections and the closing paragraph's four statements" {
    local sparkle
    sparkle="$(source "$BATS_TEST_DIRNAME/../lib/sparkle.sh" && printf '%s' "$SPARKLE_VERSION")"
    [ -n "$sparkle" ]
    grep -qx "## What's new" "$TEMPLATE"
    grep -qx '## Fixes' "$TEMPLATE"
    grep -qF "$SENTENCE" "$TEMPLATE"
    grep -qF 'Corresponding Source for this release is the attached file whose name ends in `-source.tar.gz`' "$TEMPLATE"
    grep -qF "https://github.com/sparkle-project/Sparkle/tree/$sparkle" "$TEMPLATE"
    grep -qF 'The cleaning engine is Mole' "$TEMPLATE"
    grep -qF 'credited in the NOTICE file' "$TEMPLATE"
    # The placeholder lines are what the preflight refuses in a real release's notes.
    [ "$(grep -c 'Replace this line' "$TEMPLATE")" -eq 2 ]
    [ -z "$(grep 'TODO' "$TEMPLATE" || true)" ]
}

@test "the release-notes README requires the same first sentence and the same Sparkle source" {
    local sparkle readme="$BATS_TEST_DIRNAME/../../release-notes/README.md"
    sparkle="$(source "$BATS_TEST_DIRNAME/../lib/sparkle.sh" && printf '%s' "$SPARKLE_VERSION")"
    grep -qF "$SENTENCE" "$readme"
    grep -qF "https://github.com/sparkle-project/Sparkle/tree/$sparkle" "$readme"
}

# hook ARGS...: runs release-hook.sh from $TMP, keeping stdout in $OUT, stderr in
# $ERR and the exit status in $status.
hook() {
    status=0
    (cd "$TMP" && "$HOOK" "$@") > "$OUT" 2> "$ERR" || status=$?
}

# add_hook: a token-fixture stub that logs what it saw to $HOOK_LOG and exits
# with $HOOK_EXIT.
add_hook() {
    cat > "$REPO/scripts/release-hooks/token-fixture" << 'STUB'
#!/bin/bash
{
    printf 'arg=%s\n' "$@"
    printf 'pwd=%s\n' "$PWD"
    printf 'url=%s\n' "${RFM_FIXTURE_TOKEN_URL-unset}"
} > "$HOOK_LOG"
echo "hook output"
exit "${HOOK_EXIT:-0}"
STUB
    chmod +x "$REPO/scripts/release-hooks/token-fixture"
    HOOK_LOG="$TMP/hook.log"
    export HOOK_LOG
}

@test "an absent hook is skipped with a notice" {
    hook token-fixture 1.2.3 "$PUBLISHED" "$TMP/paths.txt"
    [ "$status" -eq 0 ]
    [ "$(cat "$ERR")" = "skipped: no release hook token-fixture" ]
    [ ! -s "$OUT" ]
    [ ! -e "$TMP/paths.txt" ]
    # After the name, --required is an argument for the hook, not the flag.
    hook token-fixture 1.2.3 --required
    [ "$status" -eq 0 ]
    [ "$(cat "$ERR")" = "skipped: no release hook token-fixture" ]
}

@test "an absent hook with --required is an error" {
    hook --required token-fixture 1.2.3 "$PUBLISHED" "$TMP/paths.txt"
    [ "$status" -eq 1 ]
    grep -qF 'error: release hook token-fixture is required' "$ERR"
    [ -z "$(grep 'skipped' "$ERR" || true)" ]
}

@test "a present hook gets its arguments and environment, and its exit status is returned" {
    add_hook
    export RFM_FIXTURE_TOKEN_URL=https://example.invalid/fixture
    export RFM_FIXTURE_TOKEN_KEY=s3cret-key-value
    HOOK_EXIT=7
    export HOOK_EXIT
    hook token-fixture 1.2.3 "$PUBLISHED" "$TMP/with space/paths.txt"
    [ "$status" -eq 7 ]
    [ "$(cat "$HOOK_LOG")" = "arg=1.2.3
arg=$PUBLISHED
arg=$TMP/with space/paths.txt
pwd=$TMP
url=https://example.invalid/fixture" ]
    grep -qx 'hook output' "$OUT"
    grep -qx 'running release hook token-fixture' "$ERR"
    [ -z "$(grep -s 's3cret-key-value' "$OUT" "$ERR" || true)" ]
    HOOK_EXIT=0
    hook token-fixture 1.2.3 "$PUBLISHED" "$TMP/paths.txt"
    [ "$status" -eq 0 ]
}

@test "--required counts only before the name, and a present hook runs with it" {
    add_hook
    hook --required token-fixture --required x
    [ "$status" -eq 0 ]
    [ "$(sed -n 1,2p "$HOOK_LOG")" = "arg=--required
arg=x" ]
}

@test "a hook that is not an executable file is an error, required or not" {
    add_hook
    chmod -x "$REPO/scripts/release-hooks/token-fixture"
    hook token-fixture 1.2.3
    [ "$status" -eq 1 ]
    grep -qF 'error: release hook token-fixture exists but scripts/release-hooks/token-fixture is not an executable file' "$ERR"
    hook --required token-fixture 1.2.3
    [ "$status" -eq 1 ]
    rm "$REPO/scripts/release-hooks/token-fixture"
    mkdir "$REPO/scripts/release-hooks/token-fixture"
    hook token-fixture 1.2.3
    [ "$status" -eq 1 ]
    [ ! -e "$HOOK_LOG" ]
}

@test "the hook dispatcher refuses names that could leave the hooks folder" {
    local name
    add_hook
    for name in ../lib/version.sh Token-Fixture token_fixture token.fixture README.md 1fixture -x "a b"; do
        hook "$name"
        [ "$status" -eq 2 ]
        grep -qF 'error: not a release hook name' "$ERR"
    done
    hook
    [ "$status" -eq 2 ]
    grep -qF 'error: a hook name is required' "$ERR"
    hook --required
    [ "$status" -eq 2 ]
    hook --help
    [ "$status" -eq 0 ]
    grep -qF 'Usage: scripts/release-hook.sh [--required] <name> [args...]' "$OUT"
    [ ! -e "$HOOK_LOG" ]
}

@test "the repository ships no release hook yet, so token-fixture is a no-op today" {
    # Plan 5 changes this test when it adds scripts/release-hooks/token-fixture.
    local hooks="$BATS_TEST_DIRNAME/../release-hooks"
    [ "$(find "$hooks" -mindepth 1 -maxdepth 1 ! -name .DS_Store -exec basename {} \;)" = "README.md" ]
    status=0
    (cd "$TMP" && "$BATS_TEST_DIRNAME/../release-hook.sh" token-fixture 1.2.3 "$PUBLISHED" "$TMP/paths.txt") > "$OUT" 2> "$ERR" || status=$?
    [ "$status" -eq 0 ]
    [ "$(cat "$ERR")" = "skipped: no release hook token-fixture" ]
    [ ! -e "$TMP/paths.txt" ]
}
