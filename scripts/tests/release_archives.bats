#!/usr/bin/env bats
# Checks the release archive scripts without a network, a keychain or a real
# Sparkle: make-update-archive.sh, release-summary.sh, make-source-archive.sh
# and make-appcast.sh, and the CryptoKit key-pair helper that the tests and the
# update rehearsal use. Scripts that read Config/Distribution.xcconfig or run
# git run as copies inside a throwaway folder, with a fixture configuration
# that names another repository, so a value a script hard-codes fails a test.
# Sparkle's tools are stubs that log their arguments and standard input to
# $STATE. The last test runs the real tools when SPARKLE_BIN holds them (CI's
# app job sets it after the build). The synthetic app comes from fake_app.bash.

bats_require_minimum_version 1.5.0

load fake_app

setup() {
    TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
    STATE="$TMP/state"
    SCRIPTS="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
    mkdir -p "$STATE" "$TMP/tmp" "$TMP/home"
    # The scripts make their working folders (rfm-*) in $TMPDIR, so a test can
    # check that none is left behind.
    export TMPDIR="$TMP/tmp"
    export STATE
    # git reads neither the user's nor the system's configuration or identity.
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    export GIT_AUTHOR_NAME=Tester GIT_AUTHOR_EMAIL=tester@example.invalid
    export GIT_COMMITTER_NAME=Tester GIT_COMMITTER_EMAIL=tester@example.invalid
}

# The synthetic app, built once per file on first use (a test that changes it
# works on a copy from copy_app). Sets APP.
shared_app() {
    local dir="$BATS_FILE_TMPDIR/shared-app" reason
    # Task 9's check for clang, codesign, lipo and plutil. It runs here, in the
    # test, because skip cannot work inside $(make_fake_app ...); a file-wide
    # skip from setup_file would also skip the tests that need no app.
    reason="$(fake_app_missing_tool)"
    if [[ -n "$reason" ]]; then
        skip "$reason"
    fi
    if [[ ! -e "$BATS_FILE_TMPDIR/shared-app.built" ]]; then
        rm -rf "$dir"
        mkdir -p "$dir"
        make_fake_app "$dir" > "$BATS_FILE_TMPDIR/shared-app.path" || return 1
        : > "$BATS_FILE_TMPDIR/shared-app.built"
    fi
    APP="$(tail -n 1 "$BATS_FILE_TMPDIR/shared-app.path")"
}

# A private copy of the shared app in DIR/RoomForMac.app. Sets APP.
copy_app() {
    shared_app
    mkdir -p "$1"
    ditto "$APP" "$1/RoomForMac.app"
    APP="$1/RoomForMac.app"
}

# No working folder of a script is left in $TMPDIR.
no_work_left() {
    [ -z "$(find "$TMPDIR" -maxdepth 1 -name 'rfm-*' -print)" ]
}

# Every entry name of a tar archive, as tar wrote it, then the pax header keys
# that carry an extended attribute. `tar -t` hides the "._" AppleDouble entries
# that macOS tar writes for attributes, so the raw archive is read instead.
raw_tar_entries() {
    python3 - "$1" << 'PY'
import sys
import tarfile

with tarfile.open(sys.argv[1]) as archive:
    for member in archive:
        print("entry", member.name)
        for key in member.pax_headers:
            if "xattr" in key:
                print("xattr", key)
PY
}

@test "make-update-archive.sh --help prints the usage and exits 0" {
    run "$SCRIPTS/make-update-archive.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == "Usage: scripts/make-update-archive.sh <RoomForMac.app> <out.tar.xz>"* ]]
}

@test "make-update-archive.sh refuses bad arguments with exit 2 and writes nothing" {
    local script="$SCRIPTS/make-update-archive.sh"
    mkdir -p "$TMP/RoomForMac.app/Contents" "$TMP/Other.app/Contents" "$TMP/NotAnApp/RoomForMac.app"
    run "$script"
    [ "$status" -eq 2 ]
    [[ "$output" == *"expected <RoomForMac.app> <out.tar.xz>"* ]] || return 1
    run "$script" "$TMP/Other.app" "$TMP/out.tar.xz"
    [ "$status" -eq 2 ]
    [[ "$output" == *"the app must be named RoomForMac.app (got Other.app)"* ]] || return 1
    run "$script" "$TMP/NotAnApp/RoomForMac.app" "$TMP/out.tar.xz"
    [ "$status" -eq 2 ]
    [[ "$output" == *"not an app bundle"* ]] || return 1
    run "$script" "$TMP/RoomForMac.app" "$TMP/out.zip"
    [ "$status" -eq 2 ]
    [[ "$output" == *"the archive name must end in .tar.xz"* ]] || return 1
    run "$script" "$TMP/RoomForMac.app" "$TMP/no-such-folder/out.tar.xz"
    [ "$status" -eq 2 ]
    [[ "$output" == *"does not exist"* ]] || return 1
    [ ! -e "$TMP/out.tar.xz" ]
    no_work_left
}

@test "make-update-archive.sh packs RoomForMac.app at the archive root and prints its size and digest" {
    shared_app
    local out="$TMP/RoomForMac-1.2.3.tar.xz" bytes sum
    run --separate-stderr "$SCRIPTS/make-update-archive.sh" "$APP" "$out"
    [ "$status" -eq 0 ]
    bytes="$(wc -c < "$out" | tr -d ' ')"
    sum="$(shasum -a 256 "$out" | cut -d' ' -f1)"
    [ "$output" = "$out $bytes $sum" ]
    [ "$(tar -tJf "$out" | sed -n 1p)" = "RoomForMac.app/" ]
    [ "$(tar -tJf "$out" | grep -vc '^RoomForMac\.app/')" = "0" ]
    no_work_left
}

@test "the update archive keeps every symlink of the app as a symlink" {
    shared_app
    local out="$TMP/RoomForMac-1.2.3.tar.xz" expected actual
    "$SCRIPTS/make-update-archive.sh" "$APP" "$out" > /dev/null
    expected="$(find "$APP" -type l | wc -l | tr -d ' ')"
    actual="$(tar -tvJf "$out" | grep -c '^l')"
    [ "$expected" -gt 0 ]
    [ "$actual" -eq "$expected" ]
}

@test "the update archive holds no AppleDouble entries and no extended attributes" {
    command -v python3 > /dev/null || skip "python3 is required to read the raw archive"
    copy_app "$TMP/app"
    local out="$TMP/RoomForMac-1.2.3.tar.xz" entries
    # An attribute on a file makes macOS tar write a "._" entry for it, unless
    # COPYFILE_DISABLE is set, and a pax header for it, unless --no-xattrs is.
    xattr -w com.example.rfm-test 1 "$APP/Contents/Info.plist"
    "$SCRIPTS/make-update-archive.sh" "$APP" "$out" > /dev/null
    entries="$(raw_tar_entries "$out")"
    [[ "$entries" == *"entry RoomForMac.app/Contents/Info.plist"* ]] || return 1
    [[ "$entries" != *"/._"* ]] || return 1
    [[ "$entries" != *"entry ._"* ]] || return 1
    [[ "$entries" != *"xattr "* ]]
}

@test "the update archive unpacks into an app that passes strict verification" {
    shared_app
    local out="$TMP/RoomForMac-1.2.3.tar.xz"
    "$SCRIPTS/make-update-archive.sh" "$APP" "$out" > /dev/null
    mkdir "$TMP/unpacked"
    tar -xJf "$out" -C "$TMP/unpacked"
    codesign --verify --deep --strict "$TMP/unpacked/RoomForMac.app"
}

@test "an app whose signature no longer verifies makes no archive and leaves no working folder" {
    copy_app "$TMP/app"
    printf '\n<!-- changed after signing -->\n' >> "$APP/Contents/Info.plist"
    run "$SCRIPTS/make-update-archive.sh" "$APP" "$TMP/RoomForMac-1.2.3.tar.xz"
    [ "$status" -eq 1 ]
    [[ "$output" == *"fails strict verification"* ]] || return 1
    [ ! -e "$TMP/RoomForMac-1.2.3.tar.xz" ]
    no_work_left
}

@test "the archive is verified with codesign --verify --deep --strict on the unpacked copy" {
    shared_app
    cat > "$TMP/codesign-spy" << 'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$STATE/codesign.log"
STUB
    chmod +x "$TMP/codesign-spy"
    run env CODESIGN="$TMP/codesign-spy" "$SCRIPTS/make-update-archive.sh" "$APP" "$TMP/RoomForMac-1.2.3.tar.xz"
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$STATE/codesign.log" | tr -d ' ')" = "1" ]
    [[ "$(cat "$STATE/codesign.log")" == "--verify --deep --strict $TMPDIR/rfm-update-archive."*"/extracted/RoomForMac.app" ]]
}

@test "ed25519-keypair.swift prints a fresh seed and public key, 32 bytes each in base64" {
    command -v swift > /dev/null || skip "swift is required"
    local pattern='^[A-Za-z0-9+/]{43}= [A-Za-z0-9+/]{43}=$' first
    run --separate-stderr env HOME="$TMP/home" swift "$SCRIPTS/lib/ed25519-keypair.swift"
    [ "$status" -eq 0 ]
    [[ "$output" =~ $pattern ]] || return 1
    first="$output"
    run --separate-stderr env HOME="$TMP/home" swift "$SCRIPTS/lib/ed25519-keypair.swift"
    [ "$status" -eq 0 ]
    [ "$output" != "$first" ]
}

# A copy of the scripts that read Config/Distribution.xcconfig, under
# $TMP/root, with a fixture configuration that names another repository and
# site. Sets ROOT.
make_root() {
    ROOT="$TMP/root"
    local script
    mkdir -p "$ROOT/scripts/lib" "$ROOT/Config"
    for script in make-appcast.sh release-summary.sh; do
        if [[ -f "$SCRIPTS/$script" ]]; then
            cp "$SCRIPTS/$script" "$ROOT/scripts/"
        fi
    done
    cp "$SCRIPTS"/lib/*.sh "$SCRIPTS"/lib/ed25519-verify.swift "$ROOT/scripts/lib/"
    cat > "$ROOT/Config/Distribution.xcconfig" << 'XCCONFIG'
// Fixture for release_archives.bats: not RoomForMac's real values.
RFM_REPOSITORY = example/Widget
RFM_FEED_URL = https:/$()/github.com/example/Widget/releases/latest/download/appcast.xml
RFM_SITE_URL = https:/$()/example.github.io/Widget
RFM_DMG_VOLUME_NAME = RoomForMac
RFM_SPARKLE_PUBLIC_KEY =
XCCONFIG
}

# One field of a JSON document on stdin, by dotted path, printed as text.
json_get() {
    python3 -c '
import json
import sys

value = json.load(sys.stdin)
for key in sys.argv[1].split("."):
    value = value[key]
print(value)
' "$1"
}

# SHA-256 of the three bytes "abc", a value that does not come from any tool
# the script uses.
ABC_SHA256=ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad

@test "release-summary.sh --help prints the usage and exits 0" {
    make_root
    run "$ROOT/scripts/release-summary.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == "Usage: scripts/release-summary.sh --dmg <RoomForMac.dmg> --tag vX.Y.Z [--repository OWNER/NAME]"* ]]
}

@test "release-summary.sh prints latest.json for the disk image on one line" {
    make_root
    printf 'abc' > "$TMP/RoomForMac.dmg"
    run --separate-stderr env RFM_RELEASE_DATE=2026-09-29 "$ROOT/scripts/release-summary.sh" \
        --dmg "$TMP/RoomForMac.dmg" --tag v1.2.3
    [ "$status" -eq 0 ]
    [ "$output" = '{"schema":1,"version":"1.2.3","build":1002003,"minimum_macos":"26.0","date":"2026-09-29","dmg":{"url":"https://github.com/example/Widget/releases/download/v1.2.3/RoomForMac.dmg","size":3,"sha256":"'"$ABC_SHA256"'"}}' ]
    [ -z "$stderr" ]
}

@test "release-summary.sh gives valid JSON whose size and digest are the file's" {
    command -v python3 > /dev/null || skip "python3 is required to parse the JSON"
    local date_pattern='^20[0-9]{2}-[0-9]{2}-[0-9]{2}$'
    make_root
    head -c 100003 /dev/urandom > "$TMP/RoomForMac.dmg"
    run --separate-stderr "$ROOT/scripts/release-summary.sh" --dmg "$TMP/RoomForMac.dmg" --tag v0.1.0
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "1" ]
    [ "$(printf '%s' "$output" | json_get schema)" = "1" ]
    [ "$(printf '%s' "$output" | json_get version)" = "0.1.0" ]
    [ "$(printf '%s' "$output" | json_get build)" = "1000" ]
    [ "$(printf '%s' "$output" | json_get minimum_macos)" = "26.0" ]
    [ "$(printf '%s' "$output" | json_get dmg.size)" = "100003" ]
    [ "$(printf '%s' "$output" | json_get dmg.sha256)" = "$(shasum -a 256 "$TMP/RoomForMac.dmg" | cut -d' ' -f1)" ]
    [[ "$(printf '%s' "$output" | json_get date)" =~ $date_pattern ]]
}

@test "release-summary.sh takes the repository from --repository, else from the configuration" {
    make_root
    printf 'abc' > "$TMP/RoomForMac.dmg"
    run "$ROOT/scripts/release-summary.sh" --dmg "$TMP/RoomForMac.dmg" --tag v1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *'"url":"https://github.com/example/Widget/releases/download/v1.2.3/RoomForMac.dmg"'* ]] || return 1
    run "$ROOT/scripts/release-summary.sh" --dmg "$TMP/RoomForMac.dmg" --tag v1.2.3 --repository other/Repo.name
    [ "$status" -eq 0 ]
    [[ "$output" == *'"url":"https://github.com/other/Repo.name/releases/download/v1.2.3/RoomForMac.dmg"'* ]]
}

@test "release-summary.sh refuses bad arguments with exit 2" {
    make_root
    printf 'abc' > "$TMP/RoomForMac.dmg"
    local script="$ROOT/scripts/release-summary.sh"
    run "$script" --tag v1.2.3
    [ "$status" -eq 2 ]
    [[ "$output" == *"--dmg is required"* ]] || return 1
    run "$script" --dmg "$TMP/RoomForMac.dmg"
    [ "$status" -eq 2 ]
    [[ "$output" == *"--tag is required"* ]] || return 1
    run "$script" --dmg "$TMP/RoomForMac.dmg" --tag
    [ "$status" -eq 2 ]
    [[ "$output" == *"--tag needs a value"* ]] || return 1
    run "$script" --dmg "$TMP/RoomForMac.dmg" --tag v1.2.3 --verbose
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown argument: --verbose"* ]] || return 1
    run "$script" --dmg "$TMP/RoomForMac.dmg" --tag v1.2.3 --repository 'no slash'
    [ "$status" -eq 2 ]
    [[ "$output" == *"--repository must look like owner/name"* ]] || return 1
    run env RFM_RELEASE_DATE=yesterday "$script" --dmg "$TMP/RoomForMac.dmg" --tag v1.2.3
    [ "$status" -eq 2 ]
    [[ "$output" == *"RFM_RELEASE_DATE must be YYYY-MM-DD"* ]]
}

@test "release-summary.sh refuses a tag that is not a strict vX.Y.Z" {
    make_root
    printf 'abc' > "$TMP/RoomForMac.dmg"
    local tag
    for tag in 1.2.3 v1.2 v01.2.3 v1.2.3-beta v1.1000.0 v2001.0.0; do
        run "$ROOT/scripts/release-summary.sh" --dmg "$TMP/RoomForMac.dmg" --tag "$tag"
        if [ "$status" -ne 1 ] || [[ "$output" != *"the tag must be a strict vX.Y.Z"* ]]; then
            echo "tag $tag: status $status, output: $output" >&2
            return 1
        fi
    done
}

@test "release-summary.sh refuses a missing, misnamed or empty disk image" {
    make_root
    local script="$ROOT/scripts/release-summary.sh"
    run "$script" --dmg "$TMP/RoomForMac.dmg" --tag v1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"no such disk image"* ]] || return 1
    printf 'abc' > "$TMP/Other.dmg"
    run "$script" --dmg "$TMP/Other.dmg" --tag v1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"the disk image must be named RoomForMac.dmg"* ]] || return 1
    : > "$TMP/RoomForMac.dmg"
    run "$script" --dmg "$TMP/RoomForMac.dmg" --tag v1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"the disk image is empty"* ]]
}

# A superproject in $REPO whose submodule vendor/mole is the local repository
# $UPSTREAM, with the tags v0.1.0 (before the submodule exists) and v1.2.3
# (with the engine's first commit). The script runs as a copy inside it, and
# the copy is untracked. Sets REPO, UPSTREAM and SCRIPT.
make_source_repo() {
    UPSTREAM="$TMP/mole-upstream"
    REPO="$TMP/repo"
    git -c init.defaultBranch=main init -q "$UPSTREAM"
    printf 'the engine licence\n' > "$UPSTREAM/LICENSE"
    printf 'engine 1\n' > "$UPSTREAM/mole"
    git -C "$UPSTREAM" add -A
    git -C "$UPSTREAM" commit -q -m "engine 1"

    git -c init.defaultBranch=main init -q "$REPO"
    mkdir -p "$REPO/patches/mole"
    printf 'the app licence\n' > "$REPO/LICENSE"
    printf 'the notice\n' > "$REPO/NOTICE"
    printf 'patch one\n' > "$REPO/patches/mole/0001-first.patch"
    git -C "$REPO" add LICENSE NOTICE patches
    git -C "$REPO" commit -q -m "before the engine"
    git -C "$REPO" tag v0.1.0
    git -C "$REPO" -c protocol.file.allow=always submodule add -q "$UPSTREAM" vendor/mole
    git -C "$REPO" commit -q -m "release 1.2.3"
    git -C "$REPO" tag -a v1.2.3 -m "RoomForMac 1.2.3"

    mkdir -p "$REPO/scripts/lib"
    cp "$SCRIPTS/make-source-archive.sh" "$REPO/scripts/"
    cp "$SCRIPTS"/lib/*.sh "$REPO/scripts/lib/"
    SCRIPT="$REPO/scripts/make-source-archive.sh"
}

@test "make-source-archive.sh --help prints the usage and exits 0" {
    make_source_repo
    run "$SCRIPT" --help
    [ "$status" -eq 0 ]
    [[ "$output" == "Usage: scripts/make-source-archive.sh <vX.Y.Z> <out.tar.gz>"* ]]
}

@test "make-source-archive.sh packs the tag and the engine commit it records under RoomForMac-X.Y.Z/" {
    make_source_repo
    local out="$TMP/RoomForMac-1.2.3-source.tar.gz" bytes sum tree
    run --separate-stderr "$SCRIPT" v1.2.3 "$out"
    [ "$status" -eq 0 ]
    bytes="$(wc -c < "$out" | tr -d ' ')"
    sum="$(shasum -a 256 "$out" | cut -d' ' -f1)"
    [ "$output" = "$out $bytes $sum" ]
    [ "$(tar -tzf "$out" | sed -n 1p)" = "RoomForMac-1.2.3/" ]
    [ "$(tar -tzf "$out" | grep -vc '^RoomForMac-1\.2\.3/')" = "0" ]
    mkdir "$TMP/unpacked"
    tar -xzf "$out" -C "$TMP/unpacked"
    tree="$TMP/unpacked/RoomForMac-1.2.3"
    [ "$(cat "$tree/LICENSE")" = "the app licence" ]
    [ "$(cat "$tree/NOTICE")" = "the notice" ]
    [ "$(cat "$tree/patches/mole/0001-first.patch")" = "patch one" ]
    [ "$(cat "$tree/vendor/mole/LICENSE")" = "the engine licence" ]
    [ "$(cat "$tree/vendor/mole/mole")" = "engine 1" ]
    [ -f "$tree/.gitmodules" ]
    [ ! -e "$tree/scripts" ]
    no_work_left
}

@test "the source archive comes from git objects and never from the working tree" {
    make_source_repo
    local tree
    # All of this happens after the tag, and none of it may reach the archive.
    printf 'dirty edit\n' > "$REPO/LICENSE"
    printf 'secret\n' > "$REPO/untracked.txt"
    printf 'engine 2\n' > "$REPO/vendor/mole/mole"
    git -C "$REPO/vendor/mole" commit -q -am "engine 2"
    printf 'engine 3, not committed\n' > "$REPO/vendor/mole/mole"
    printf 'more\n' > "$REPO/vendor/mole/added.txt"
    run "$SCRIPT" v1.2.3 "$TMP/source.tar.gz"
    [ "$status" -eq 0 ]
    mkdir "$TMP/unpacked"
    tar -xzf "$TMP/source.tar.gz" -C "$TMP/unpacked"
    tree="$TMP/unpacked/RoomForMac-1.2.3"
    [ "$(cat "$tree/LICENSE")" = "the app licence" ]
    [ ! -e "$tree/untracked.txt" ]
    [ "$(cat "$tree/vendor/mole/mole")" = "engine 1" ]
    [ ! -e "$tree/vendor/mole/added.txt" ]
}

@test "make-source-archive.sh refuses bad arguments with exit 2 and writes nothing" {
    make_source_repo
    run "$SCRIPT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"expected <vX.Y.Z> <out.tar.gz>"* ]] || return 1
    run "$SCRIPT" v1.2.3
    [ "$status" -eq 2 ]
    run "$SCRIPT" v1.2.3 "$TMP/source.zip"
    [ "$status" -eq 2 ]
    [[ "$output" == *"the archive name must end in .tar.gz"* ]] || return 1
    run "$SCRIPT" v1.2.3 "$TMP/no-such-folder/source.tar.gz"
    [ "$status" -eq 2 ]
    [[ "$output" == *"does not exist"* ]] || return 1
    [ ! -e "$TMP/source.tar.gz" ]
    no_work_left
}

@test "make-source-archive.sh refuses a tag that is not a strict vX.Y.Z or does not exist" {
    make_source_repo
    local tag
    for tag in 1.2.3 v1.2 v01.2.3 v1.2.3-beta; do
        run "$SCRIPT" "$tag" "$TMP/source.tar.gz"
        if [ "$status" -ne 1 ] || [[ "$output" != *"the tag must be a strict vX.Y.Z"* ]]; then
            echo "tag $tag: status $status, output: $output" >&2
            return 1
        fi
    done
    run "$SCRIPT" v9.9.9 "$TMP/source.tar.gz"
    [ "$status" -eq 1 ]
    [[ "$output" == *"the tag v9.9.9 does not exist"* ]] || return 1
    [ ! -e "$TMP/source.tar.gz" ]
    no_work_left
}

@test "make-source-archive.sh refuses a tag that records no engine" {
    make_source_repo
    run "$SCRIPT" v0.1.0 "$TMP/source.tar.gz"
    [ "$status" -eq 1 ]
    [[ "$output" == *"the tag v0.1.0 does not record vendor/mole as a submodule"* ]] || return 1
    [ ! -e "$TMP/source.tar.gz" ]
}

@test "make-source-archive.sh refuses an engine commit that vendor/mole does not hold" {
    make_source_repo
    git -C "$REPO" update-index --cacheinfo "160000,1111111111111111111111111111111111111111,vendor/mole"
    git -C "$REPO" commit -q -m "point the engine at a commit nobody has"
    git -C "$REPO" tag v1.2.4
    run "$SCRIPT" v1.2.4 "$TMP/source.tar.gz"
    [ "$status" -eq 1 ]
    [[ "$output" == *"vendor/mole has no commit 1111111111111111111111111111111111111111, which v1.2.4 records"* ]] || return 1
    [ ! -e "$TMP/source.tar.gz" ]
    no_work_left
}

@test "make-source-archive.sh refuses a checkout without the engine" {
    make_source_repo
    rm -rf "$REPO/vendor/mole"
    run "$SCRIPT" v1.2.3 "$TMP/source.tar.gz"
    [ "$status" -eq 1 ]
    [[ "$output" == *"vendor/mole is not checked out"* ]] || return 1
    [ ! -e "$TMP/source.tar.gz" ]
}

@test "make-source-archive.sh refuses a tag whose tree has no engine patches" {
    make_source_repo
    git -C "$REPO" rm -q -r patches
    git -C "$REPO" commit -q -m "drop the patches"
    git -C "$REPO" tag v1.2.5
    run "$SCRIPT" v1.2.5 "$TMP/source.tar.gz"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no patches/mole/*.patch at v1.2.5"* ]] || return 1
    [ ! -e "$TMP/source.tar.gz" ]
    no_work_left
}

# A base64 seed that is not a real key: the stubs never check it, and the tests
# look for it in argv and in output.
KEY="dGVzdC1zZWVkLW5vdC1hLXJlYWwta2V5LTMyYnl0ZQ=="

# Stand-ins for Sparkle's generate_appcast and sign_update in $TMP/sparkle-bin.
# They log their arguments and standard input to $STATE. generate_appcast adds
# one item for the .tar.xz in the folder it is given and keeps the items of an
# appcast.xml already there, as the real tool does (at most ten in all); with
# STUB_MODE set it misbehaves in one way at a time. Sets STUBS.
stub_sparkle() {
    STUBS="$TMP/sparkle-bin"
    mkdir -p "$STUBS"
    cat > "$STUBS/generate_appcast" << 'STUB'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$STATE/generate_appcast.argv"
cat > "$STATE/generate_appcast.stdin"
prefix="" link="" dir=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ed-key-file)
            if [[ "$2" != "-" ]]; then
                echo "stub generate_appcast: the key must come from standard input" >&2
                exit 64
            fi
            shift
            ;;
        --download-url-prefix)
            prefix="$2"
            shift
            ;;
        --link)
            link="$2"
            shift
            ;;
        --maximum-deltas | --maximum-versions) shift ;;
        --embed-release-notes) ;;
        -*)
            echo "stub generate_appcast: unknown option $1" >&2
            exit 64
            ;;
        *) dir="$1" ;;
    esac
    shift
done
ls "$dir" > "$STATE/stage.list"
mode="${STUB_MODE:-}"
case "$mode" in
    fail)
        echo "generate_appcast: something went wrong" >&2
        exit 1
        ;;
    leak)
        echo "generate_appcast: cannot read the key $(cat "$STATE/generate_appcast.stdin")" >&2
        exit 1
        ;;
esac

archive="$(ls "$dir"/*.tar.xz)"
name="$(basename "$archive")"
version="${name#RoomForMac-}"
version="${version%.tar.xz}"
IFS=. read -r major minor patch <<< "$version"
build=$((major * 1000000 + minor * 1000 + patch))
cp "$dir/RoomForMac-$version.md" "$STATE/staged.md"
cp "$dir/RoomForMac-$version.tar.md" "$STATE/staged.tar.md"

item_build="$build" short="$version" minimum="26.0" url="$prefix$name" hardware="" notes="            <description><![CDATA[Release notes of $version]]></description>"
length="$(wc -c < "$archive" | tr -d ' ')"
signature="$(printf 'A%.0s' {1..86})=="
case "$mode" in
    skipped) echo "Skipped $name: its code signature is invalid" ;;
    wrong-build) item_build=$((build + 1)) ;;
    wrong-short) short="9.9.9" ;;
    wrong-minimum) minimum="25.0" ;;
    wrong-url) url="https://example.invalid/$name" ;;
    wrong-length) length=$((length + 1)) ;;
    bad-signature) signature="c2hvcnQ=" ;;
    no-notes) notes="" ;;
    hardware) hardware="            <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>" ;;
esac

new_item() {
    cat << ITEM
        <item>
            <title>$version</title>
            <pubDate>Tue, 29 Sep 2026 12:00:00 +0000</pubDate>
            <link>$link</link>
            <sparkle:version>$item_build</sparkle:version>
            <sparkle:shortVersionString>$short</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>$minimum</sparkle:minimumSystemVersion>
$hardware
$notes
            <enclosure url="$url" length="$length" type="application/octet-stream" sparkle:edSignature="$signature"/>
        </item>
ITEM
}
# The earlier items, verbatim and at most nine of them.
old_items() {
    sed -n '/^[[:space:]]*<item>[[:space:]]*$/,/^[[:space:]]*<\/item>[[:space:]]*$/p' "$dir/appcast.xml" |
        awk '/<item>/ { n++ } n <= 9'
}

if [[ "$mode" != no-appcast ]]; then
    {
        echo '<?xml version="1.0" standalone="yes"?>'
        echo '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">'
        echo '    <channel>'
        echo '        <title>RoomForMac</title>'
        if [[ "$mode" != no-item ]]; then new_item; fi
        if [[ -f "$dir/appcast.xml" && "$mode" != drop-old ]]; then
            if [[ "$mode" == alter-old ]]; then
                old_items | sed 's|<title>\([^<]*\)</title>|<title>\1 </title>|'
            else
                old_items
            fi
        fi
        echo '    </channel>'
        echo '</rss>'
    } > "$dir/appcast.xml.new"
    mv "$dir/appcast.xml.new" "$dir/appcast.xml"
fi
STUB
    cat > "$STUBS/sign_update" << 'STUB'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$STATE/sign_update.argv"
cat > "$STATE/sign_update.stdin"
if [[ "${STUB_VERIFY:-}" == fail ]]; then
    echo "sign_update: the signature does not match the archive" >&2
    exit 1
fi
STUB
    # Stands in for lib/ed25519-verify.swift: a signature "verifies" when the
    # public key it is given is the one the stub signer is said to hold.
    cat > "$STUBS/ed25519_verify" << 'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$STATE/ed25519_verify.argv"
[[ "$1" == "${STUB_SIGNER_PUBLIC:-STUBPUBLIC}" ]]
STUB
    chmod +x "$STUBS/generate_appcast" "$STUBS/sign_update" "$STUBS/ed25519_verify"
    export ED25519_VERIFY="$STUBS/ed25519_verify" RFM_SPARKLE_PUBLIC_KEY=STUBPUBLIC
}

# make_root and stub_sparkle, for a test of make-appcast.sh.
prepare_appcast() {
    make_root
    stub_sparkle
}

# An archive and release notes for X.Y.Z under $TMP/in. The stub never unpacks
# the archive.
release_inputs() {
    mkdir -p "$TMP/in/release-notes"
    printf 'archive of %s\n' "$1" > "$TMP/in/RoomForMac-$1.tar.xz"
    printf '## What is new\n\n- release %s\n' "$1" > "$TMP/in/release-notes/$1.md"
}

# make-appcast.sh for X.Y.Z with the stub tools, writing $TMP/out/appcast-X.Y.Z.xml.
# Later options replace earlier ones, so a test can override any of them.
run_appcast() { # X.Y.Z [option…]
    local version="$1"
    shift
    mkdir -p "$TMP/out"
    release_inputs "$version"
    run env SPARKLE_BIN="$STUBS" SPARKLE_ED_PRIVATE_KEY="$KEY" "$ROOT/scripts/make-appcast.sh" \
        --archive "$TMP/in/RoomForMac-$version.tar.xz" --notes "$TMP/in/release-notes/$version.md" \
        --tag "v$version" --out "$TMP/out/appcast-$version.xml" "$@"
}

@test "make-appcast.sh --help prints the usage and exits 0" {
    prepare_appcast
    run "$ROOT/scripts/make-appcast.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == "Usage: scripts/make-appcast.sh --archive <RoomForMac-X.Y.Z.tar.xz> --notes <release-notes/X.Y.Z.md>"* ]]
}

@test "make-appcast.sh refuses missing or unusable inputs with exit 2, before any Sparkle tool runs" {
    prepare_appcast
    local script="$ROOT/scripts/make-appcast.sh"
    run env SPARKLE_BIN="$STUBS" SPARKLE_ED_PRIVATE_KEY="$KEY" "$script"
    [ "$status" -eq 2 ]
    [[ "$output" == *"--archive is required"* ]] || return 1
    run_appcast 1.2.3 --bogus
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown argument: --bogus"* ]] || return 1
    run_appcast 1.2.3 --notes "$TMP/no-such-notes.md"
    [ "$status" -eq 2 ]
    [[ "$output" == *"the release notes are missing or empty"* ]] || return 1
    : > "$TMP/empty-notes.md"
    run_appcast 1.2.3 --notes "$TMP/empty-notes.md"
    [ "$status" -eq 2 ]
    [[ "$output" == *"the release notes are missing or empty"* ]] || return 1
    run_appcast 1.2.3 --archive "$TMP/no-such-archive.tar.xz"
    [ "$status" -eq 2 ]
    [[ "$output" == *"no such archive"* ]] || return 1
    run_appcast 1.2.3 --previous "$TMP/no-such-appcast.xml"
    [ "$status" -eq 2 ]
    [[ "$output" == *"no such appcast"* ]] || return 1
    run_appcast 1.2.3 --out "$TMP/no-such-folder/appcast.xml"
    [ "$status" -eq 2 ]
    [[ "$output" == *"does not exist"* ]] || return 1
    run_appcast 1.2.3 --repository "not a repository"
    [ "$status" -eq 2 ]
    [[ "$output" == *"--repository must look like owner/name"* ]] || return 1
    run_appcast 1.2.3 --download-url-prefix "http://example.com/"
    [ "$status" -eq 2 ]
    [[ "$output" == *"--download-url-prefix must be an https URL ending in a slash"* ]] || return 1
    run_appcast 1.2.3 --download-url-prefix "https://example.com/no-slash"
    [ "$status" -eq 2 ]
    [[ "$output" == *"--download-url-prefix must be an https URL ending in a slash"* ]] || return 1
    [ ! -e "$STATE/generate_appcast.argv" ]
    [ ! -e "$STATE/sign_update.argv" ]
    no_work_left
}

@test "make-appcast.sh needs the key, and neither prints it nor accepts a malformed one" {
    prepare_appcast
    release_inputs 1.2.3
    local script="$ROOT/scripts/make-appcast.sh" args
    args=(--archive "$TMP/in/RoomForMac-1.2.3.tar.xz" --notes "$TMP/in/release-notes/1.2.3.md" --tag v1.2.3 --out "$TMP/appcast.xml")
    run env -u SPARKLE_ED_PRIVATE_KEY SPARKLE_BIN="$STUBS" "$script" "${args[@]}"
    [ "$status" -eq 2 ]
    [[ "$output" == *"SPARKLE_ED_PRIVATE_KEY is not set"* ]] || return 1
    run env SPARKLE_ED_PRIVATE_KEY="  " SPARKLE_BIN="$STUBS" "$script" "${args[@]}"
    [ "$status" -eq 2 ]
    [[ "$output" == *"SPARKLE_ED_PRIVATE_KEY is not set"* ]] || return 1
    run env SPARKLE_ED_PRIVATE_KEY="not base64 !!" SPARKLE_BIN="$STUBS" "$script" "${args[@]}"
    [ "$status" -eq 2 ]
    [[ "$output" == *"SPARKLE_ED_PRIVATE_KEY is not base64"* ]] || return 1
    [[ "$output" != *"not base64 !!"* ]] || return 1
    [ ! -e "$STATE/generate_appcast.argv" ]
}

@test "make-appcast.sh refuses an unstrict tag and an archive named for another version" {
    prepare_appcast
    local tag
    for tag in 1.2.3 v1.2 v01.2.3 v1.2.3-beta v1.1000.0; do
        run_appcast 1.2.3 --tag "$tag"
        if [ "$status" -ne 1 ] || [[ "$output" != *"the tag must be a strict vX.Y.Z"* ]]; then
            echo "tag $tag: status $status, output: $output" >&2
            return 1
        fi
    done
    release_inputs 9.9.9
    run_appcast 1.2.3 --archive "$TMP/in/RoomForMac-9.9.9.tar.xz"
    [ "$status" -eq 1 ]
    [[ "$output" == *"the archive is named RoomForMac-9.9.9.tar.xz, but tag v1.2.3 needs RoomForMac-1.2.3.tar.xz"* ]] || return 1
    [ ! -e "$STATE/generate_appcast.argv" ]
    [ ! -e "$TMP/out/appcast-1.2.3.xml" ]
    no_work_left
}

@test "a first release stages the archive and both spellings of its notes and writes a one-item appcast" {
    prepare_appcast
    run_appcast 1.2.3
    [ "$status" -eq 0 ]
    [ "$(cat "$STATE/stage.list")" = $'RoomForMac-1.2.3.md\nRoomForMac-1.2.3.tar.md\nRoomForMac-1.2.3.tar.xz' ]
    cmp "$TMP/in/release-notes/1.2.3.md" "$STATE/staged.md"
    cmp "$TMP/in/release-notes/1.2.3.md" "$STATE/staged.tar.md"
    [ "$(grep -c '<item>' "$TMP/out/appcast-1.2.3.xml")" = "1" ]
    [[ "$output" == *"ok: no earlier appcast: this is the first release"* ]] || return 1
    [[ "$output" == *"ok: generate_appcast accepted RoomForMac-1.2.3.tar.xz"* ]] || return 1
    [[ "$output" == *"ok: item 1002003: version 1.2.3, minimum macOS 26.0, https://github.com/example/Widget/releases/download/v1.2.3/RoomForMac-1.2.3.tar.xz"* ]] || return 1
    [[ "$output" == *"ok: sign_update verified RoomForMac-1.2.3.tar.xz against the item's signature"* ]] || return 1
    [[ "$output" == *"ok: wrote $TMP/out/appcast-1.2.3.xml, items: 1"* ]] || return 1
    no_work_left
}

@test "generate_appcast gets the documented options, with the prefix and link taken from the configuration" {
    prepare_appcast
    run_appcast 1.2.3
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$STATE/generate_appcast.argv" | tr -d ' ')" = "1" ]
    [[ "$(cat "$STATE/generate_appcast.argv")" == "--ed-key-file - --download-url-prefix https://github.com/example/Widget/releases/download/v1.2.3/ --link https://example.github.io/Widget/ --embed-release-notes --maximum-deltas 0 --maximum-versions 10 $TMPDIR/rfm-appcast."*"/stage" ]] || return 1
    [ "$(cat "$STATE/sign_update.argv")" = "--ed-key-file - --verify $TMP/in/RoomForMac-1.2.3.tar.xz $(printf 'A%.0s' {1..86})==" ]
}

@test "--repository, --download-url-prefix and --link replace the defaults" {
    prepare_appcast
    run_appcast 1.2.3 --repository other/Repo
    [ "$status" -eq 0 ]
    [[ "$(cat "$STATE/generate_appcast.argv")" == *"--download-url-prefix https://github.com/other/Repo/releases/download/v1.2.3/ "* ]] || return 1
    rm -f "$STATE/generate_appcast.argv"
    run_appcast 1.2.3 --download-url-prefix "http://127.0.0.1:8765/" --link "https://example.test/"
    [ "$status" -eq 0 ]
    [[ "$(cat "$STATE/generate_appcast.argv")" == *"--download-url-prefix http://127.0.0.1:8765/ --link https://example.test/ "* ]] || return 1
    grep -q 'enclosure url="http://127.0.0.1:8765/RoomForMac-1.2.3.tar.xz"' "$TMP/out/appcast-1.2.3.xml"
}

@test "the key reaches the Sparkle tools on standard input only, without whitespace" {
    prepare_appcast
    release_inputs 1.2.3
    run env SPARKLE_BIN="$STUBS" SPARKLE_ED_PRIVATE_KEY="$KEY"$'\n' "$ROOT/scripts/make-appcast.sh" \
        --archive "$TMP/in/RoomForMac-1.2.3.tar.xz" --notes "$TMP/in/release-notes/1.2.3.md" \
        --tag v1.2.3 --out "$TMP/appcast.xml"
    [ "$status" -eq 0 ]
    [ "$(cat "$STATE/generate_appcast.stdin")" = "$KEY" ]
    [ "$(wc -c < "$STATE/generate_appcast.stdin" | tr -d ' ')" = "${#KEY}" ]
    [ "$(cat "$STATE/sign_update.stdin")" = "$KEY" ]
    [[ "$output" != *"$KEY"* ]] || return 1
    [ "$(cat "$STATE/generate_appcast.argv" "$STATE/sign_update.argv" | grep -cF -- "$KEY")" = "0" ]
}

@test "a tool that echoes the key has it removed from the script's output" {
    prepare_appcast
    export STUB_MODE=leak
    run_appcast 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"generate_appcast: cannot read the key [key removed]"* ]] || return 1
    [[ "$output" != *"$KEY"* ]] || return 1
    [[ "$output" == *"error: generate_appcast failed"* ]]
}

@test "a second release keeps the first item byte for byte and stages the previous appcast" {
    prepare_appcast
    run_appcast 1.0.0
    [ "$status" -eq 0 ]
    run_appcast 1.1.0 --previous "$TMP/out/appcast-1.0.0.xml"
    [ "$status" -eq 0 ]
    [[ "$(cat "$STATE/stage.list")" == *"appcast.xml"* ]] || return 1
    [ "$(grep -c '<item>' "$TMP/out/appcast-1.1.0.xml")" = "2" ]
    [[ "$output" == *"ok: build 1001000 is above all 1 published builds"* ]] || return 1
    [[ "$output" == *"ok: earlier items are unchanged"* ]] || return 1
    # The first release's item, as a block, sits unchanged inside the new appcast.
    awk '/<item>/ { keep = 1 } keep { print } /<\/item>/ { keep = 0 }' "$TMP/out/appcast-1.0.0.xml" > "$TMP/first-item.xml"
    awk '/<item>/ { n++ } n == 2 && /<item>/ { keep = 1 } keep { print } /<\/item>/ { keep = 0 }' "$TMP/out/appcast-1.1.0.xml" > "$TMP/second-item.xml"
    cmp "$TMP/first-item.xml" "$TMP/second-item.xml"
}

@test "make-appcast.sh refuses a build that is not above every published one" {
    prepare_appcast
    run_appcast 1.2.3
    [ "$status" -eq 0 ]
    rm -f "$STATE/generate_appcast.argv"
    run_appcast 1.2.3 --previous "$TMP/out/appcast-1.2.3.xml" --out "$TMP/out/again.xml"
    [ "$status" -eq 1 ]
    [[ "$output" == *"build 1002003 (tag v1.2.3) is not above build 1002003"* ]] || return 1
    run_appcast 1.2.2 --previous "$TMP/out/appcast-1.2.3.xml" --out "$TMP/out/lower.xml"
    [ "$status" -eq 1 ]
    [[ "$output" == *"build 1002002 (tag v1.2.2) is not above build 1002003"* ]] || return 1
    run_appcast 1.2.4 --previous "$TMP/out/appcast-1.2.3.xml" --out "$TMP/out/higher.xml"
    [ "$status" -eq 0 ]
    [ ! -e "$TMP/out/again.xml" ]
    [ ! -e "$TMP/out/lower.xml" ]
    [ "$(wc -l < "$STATE/generate_appcast.argv" | tr -d ' ')" = "1" ]
}

@test "make-appcast.sh refuses a previous file that is not an appcast or has no readable items" {
    prepare_appcast
    printf 'not xml\n' > "$TMP/junk.xml"
    run_appcast 1.2.3 --previous "$TMP/junk.xml"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not an appcast"* ]] || return 1
    # Two items on one line: the script cannot read the layout, so it stops.
    cat > "$TMP/squashed.xml" << 'XML'
<rss version="2.0"><channel>
<item><sparkle:version>1000</sparkle:version></item><item><sparkle:version>2000</sparkle:version></item>
</channel></rss>
XML
    run_appcast 1.2.3 --previous "$TMP/squashed.xml"
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot read the items of $TMP/squashed.xml"* ]] || return 1
    [ ! -e "$STATE/generate_appcast.argv" ]
}

@test "each way the generated appcast can be wrong fails its own check and writes no appcast" {
    prepare_appcast
    local entry mode message
    for entry in \
        "skipped|generate_appcast skipped an archive" \
        "fail|generate_appcast failed" \
        "no-appcast|generate_appcast wrote no appcast.xml" \
        "no-item|no item with sparkle:version 1002003" \
        "wrong-build|no item with sparkle:version 1002003 (found: 1002004)" \
        "wrong-short|the new item's sparkle:shortVersionString is \"9.9.9\", expected \"1.2.3\"" \
        "wrong-url|the new item's enclosure url is \"https://example.invalid/RoomForMac-1.2.3.tar.xz\"" \
        "wrong-length|the new item's enclosure length is" \
        "wrong-minimum|the new item's sparkle:minimumSystemVersion is \"25.0\", expected \"26.0\"" \
        "bad-signature|the new item has no usable sparkle:edSignature (got \"c2hvcnQ=\")" \
        "no-notes|the new item embeds no release notes" \
        "hardware|the appcast carries sparkle:hardwareRequirements"; do
        mode="${entry%%|*}"
        message="${entry#*|}"
        rm -f "$TMP/out/appcast-1.2.3.xml"
        export STUB_MODE="$mode"
        run_appcast 1.2.3
        if [ "$status" -ne 1 ] || [[ "$output" != *"error: "*"$message"* ]] || [ -e "$TMP/out/appcast-1.2.3.xml" ]; then
            echo "STUB_MODE=$mode: status $status, output: $output" >&2
            return 1
        fi
        no_work_left
    done
}

@test "a changed earlier item and a dropped earlier item both fail, naming the item" {
    prepare_appcast
    run_appcast 1.0.0
    [ "$status" -eq 0 ]
    export STUB_MODE=alter-old
    run_appcast 1.1.0 --previous "$TMP/out/appcast-1.0.0.xml"
    [ "$status" -eq 1 ]
    [[ "$output" == *"earlier item 1000000 changed in the new appcast"* ]] || return 1
    [ ! -e "$TMP/out/appcast-1.1.0.xml" ]
    export STUB_MODE=drop-old
    run_appcast 1.1.0 --previous "$TMP/out/appcast-1.0.0.xml"
    [ "$status" -eq 1 ]
    [[ "$output" == *"earlier item 1000000 is missing from the new appcast"* ]] || return 1
    [ ! -e "$TMP/out/appcast-1.1.0.xml" ]
}

@test "an item beyond the newest nine may fall out of the feed, as maximum-versions 10 does" {
    prepare_appcast
    local patch previous="" feed
    for patch in 0 1 2 3 4 5 6 7 8 9 10; do
        feed="$TMP/out/appcast-1.0.$patch.xml"
        if [ -n "$previous" ]; then
            run_appcast "1.0.$patch" --previous "$previous"
        else
            run_appcast "1.0.$patch"
        fi
        if [ "$status" -ne 0 ]; then
            echo "release 1.0.$patch: status $status, output: $output" >&2
            return 1
        fi
        previous="$feed"
    done
    [ "$(grep -c '<item>' "$previous")" = "10" ]
    [ "$(grep -c '<sparkle:version>1000000<' "$previous")" = "0" ]
    [ "$(grep -c '<sparkle:version>1000001<' "$previous")" = "1" ]
    [ "$(grep -c '<sparkle:version>1000010<' "$previous")" = "1" ]
}

@test "make-appcast.sh fails when sign_update does not verify the archive, and writes no appcast" {
    prepare_appcast
    export STUB_VERIFY=fail
    run_appcast 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"sign_update: the signature does not match the archive"* ]] || return 1
    [[ "$output" == *"error: sign_update does not verify RoomForMac-1.2.3.tar.xz against the signature in the new item"* ]] || return 1
    [ ! -e "$TMP/out/appcast-1.2.3.xml" ]
    no_work_left
}

@test "GENERATE_APPCAST and SIGN_UPDATE stand in for the Sparkle folder" {
    prepare_appcast
    release_inputs 1.2.3
    run env -u SPARKLE_BIN HOME="$TMP/home" GENERATE_APPCAST="$STUBS/generate_appcast" SIGN_UPDATE="$STUBS/sign_update" \
        SPARKLE_ED_PRIVATE_KEY="$KEY" "$ROOT/scripts/make-appcast.sh" \
        --archive "$TMP/in/RoomForMac-1.2.3.tar.xz" --notes "$TMP/in/release-notes/1.2.3.md" \
        --tag v1.2.3 --out "$TMP/appcast.xml"
    [ "$status" -eq 0 ]
    [ -f "$TMP/appcast.xml" ]
}

@test "without SPARKLE_BIN or the tool variables it asks for a build that fetches Sparkle" {
    prepare_appcast
    release_inputs 1.2.3
    mkdir -p "$TMP/home"
    run env -u SPARKLE_BIN -u GENERATE_APPCAST -u SIGN_UPDATE HOME="$TMP/home" SPARKLE_ED_PRIVATE_KEY="$KEY" \
        "$ROOT/scripts/make-appcast.sh" \
        --archive "$TMP/in/RoomForMac-1.2.3.tar.xz" --notes "$TMP/in/release-notes/1.2.3.md" \
        --tag v1.2.3 --out "$TMP/appcast.xml"
    [ "$status" -eq 1 ]
    [[ "$output" == *"build the app once"* ]] || return 1
    [ ! -e "$TMP/appcast.xml" ]
}

@test "make-appcast.sh and release-summary.sh state the same minimum macOS" {
    local appcast summary
    appcast="$(grep '^MINIMUM_MACOS=' "$SCRIPTS/make-appcast.sh")"
    summary="$(grep '^MINIMUM_MACOS=' "$SCRIPTS/release-summary.sh")"
    [ "$appcast" = 'MINIMUM_MACOS="26.0"' ]
    [ "$summary" = "$appcast" ]
}

@test "the real Sparkle tools accept a CryptoKit key, extend a feed unchanged and reject a tampered archive" {
    local bin="${SPARKLE_BIN:-}" seed public app1 app2 signature
    if [[ ! -x "$bin/generate_appcast" || ! -x "$bin/sign_update" || ! -x "$bin/generate_keys" ]]; then
        skip "set SPARKLE_BIN to Sparkle's bin folder (CI's app job does)"
    fi
    command -v swift > /dev/null || skip "swift is required for the key pair"
    command -v clang > /dev/null || skip "clang is required to build the synthetic apps"
    make_root
    read -r seed public < <(env HOME="$TMP/home" swift "$SCRIPTS/lib/ed25519-keypair.swift")
    mkdir -p "$TMP/v1" "$TMP/v2" "$TMP/in/release-notes" "$TMP/out"
    make_fake_app "$TMP/v1" --version 0.0.1 --build 1 --key "$public" > "$TMP/v1.path"
    make_fake_app "$TMP/v2" --version 0.0.2 --build 2 --key "$public" > "$TMP/v2.path"
    app1="$(tail -n 1 "$TMP/v1.path")"
    app2="$(tail -n 1 "$TMP/v2.path")"
    "$SCRIPTS/make-update-archive.sh" "$app1" "$TMP/in/RoomForMac-0.0.1.tar.xz" > /dev/null
    "$SCRIPTS/make-update-archive.sh" "$app2" "$TMP/in/RoomForMac-0.0.2.tar.xz" > /dev/null
    printf '## 0.0.1\n\n- the first release\n' > "$TMP/in/release-notes/0.0.1.md"
    printf '## 0.0.2\n\n- the second release\n' > "$TMP/in/release-notes/0.0.2.md"

    run env SPARKLE_BIN="$bin" SPARKLE_ED_PRIVATE_KEY="$seed" RFM_SPARKLE_PUBLIC_KEY="$public" HOME="$TMP/home" "$ROOT/scripts/make-appcast.sh" \
        --archive "$TMP/in/RoomForMac-0.0.1.tar.xz" --notes "$TMP/in/release-notes/0.0.1.md" \
        --tag v0.0.1 --out "$TMP/out/appcast-A.xml"
    echo "$output" >&2
    [ "$status" -eq 0 ]
    run env SPARKLE_BIN="$bin" SPARKLE_ED_PRIVATE_KEY="$seed" RFM_SPARKLE_PUBLIC_KEY="$public" HOME="$TMP/home" "$ROOT/scripts/make-appcast.sh" \
        --archive "$TMP/in/RoomForMac-0.0.2.tar.xz" --notes "$TMP/in/release-notes/0.0.2.md" \
        --tag v0.0.2 --out "$TMP/out/appcast-B.xml" --previous "$TMP/out/appcast-A.xml"
    echo "$output" >&2
    [ "$status" -eq 0 ]
    [ "$(grep -c '<item>' "$TMP/out/appcast-A.xml")" = "1" ]
    [ "$(grep -c '<item>' "$TMP/out/appcast-B.xml")" = "2" ]

    signature="$(grep 'RoomForMac-0.0.2.tar.xz' "$TMP/out/appcast-B.xml" | sed -n 's|.*sparkle:edSignature="\([^"]*\)".*|\1|p')"
    [ -n "$signature" ]
    printf '%s' "$seed" | "$bin/sign_update" --ed-key-file - --verify "$TMP/in/RoomForMac-0.0.2.tar.xz" "$signature"
    cp "$TMP/in/RoomForMac-0.0.2.tar.xz" "$TMP/tampered.tar.xz"
    printf 'x' >> "$TMP/tampered.tar.xz"
    run bash -c 'printf "%s" "$1" | "$2" --ed-key-file - --verify "$3" "$4"' _ "$seed" "$bin/sign_update" "$TMP/tampered.tar.xz" "$signature"
    [ "$status" -ne 0 ]
    # The release-key check: right key passes, another key and a tampered file fail.
    read -r _ other < <(HOME="$TMP/home" swift "$SCRIPTS/lib/ed25519-keypair.swift")
    run env HOME="$TMP/home" swift "$SCRIPTS/lib/ed25519-verify.swift" "$public" "$signature" "$TMP/in/RoomForMac-0.0.2.tar.xz"
    [ "$status" -eq 0 ]
    run env HOME="$TMP/home" swift "$SCRIPTS/lib/ed25519-verify.swift" "$other" "$signature" "$TMP/in/RoomForMac-0.0.2.tar.xz"
    [ "$status" -eq 1 ]
    run env HOME="$TMP/home" swift "$SCRIPTS/lib/ed25519-verify.swift" "$public" "$signature" "$TMP/tampered.tar.xz"
    [ "$status" -eq 1 ]
}

@test "make-appcast.sh refuses an item whose signature does not verify under the release public key" {
    prepare_appcast
    RFM_SPARKLE_PUBLIC_KEY=OTHERPUBLIC run_appcast 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not verify under the release public key"* ]] || return 1
    [ ! -e "$TMP/out/appcast-1.2.3.xml" ]
    no_work_left
}

@test "make-appcast.sh refuses an empty release public key, configured or overridden" {
    prepare_appcast
    RFM_SPARKLE_PUBLIC_KEY= run_appcast 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"RFM_SPARKLE_PUBLIC_KEY is empty"* ]] || return 1
    [ ! -e "$TMP/out/appcast-1.2.3.xml" ]
    # Unset: the fixture configuration's key is empty too.
    unset RFM_SPARKLE_PUBLIC_KEY
    run_appcast 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"RFM_SPARKLE_PUBLIC_KEY is empty"* ]] || return 1
    [ ! -e "$TMP/out/appcast-1.2.3.xml" ]
}

@test "make-appcast.sh passes the release public key, the signature and the archive to the verifier" {
    prepare_appcast
    run_appcast 1.2.3
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok: the item's signature verifies under the release public key"* ]] || return 1
    [ "$(cat "$STATE/ed25519_verify.argv")" = "STUBPUBLIC $(printf 'A%.0s' {1..86})== $TMP/in/RoomForMac-1.2.3.tar.xz" ]
}

@test "make-appcast.sh refuses a feed with two items for the new build" {
    prepare_appcast
    cat > "$STUBS/dup_appcast" << 'STUB'
#!/bin/bash
"$(dirname "$0")/generate_appcast" "$@" || exit $?
dir="${@: -1}"
python3 - "$dir/appcast.xml" << 'PY'
import re, sys
t = open(sys.argv[1]).read()
m = re.search(r"[ \t]*<item>.*?</item>\n", t, re.S)
open(sys.argv[1], "w").write(t[:m.end()] + m.group(0) + t[m.end():])
PY
STUB
    chmod +x "$STUBS/dup_appcast"
    GENERATE_APPCAST="$STUBS/dup_appcast" SIGN_UPDATE="$STUBS/sign_update" run_appcast 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"more than one item for build 1002003"* ]] || return 1
    [ ! -e "$TMP/out/appcast-1.2.3.xml" ]
}
