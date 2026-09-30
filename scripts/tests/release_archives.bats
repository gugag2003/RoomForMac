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
    mkdir -p "$STATE" "$TMP/tmp"
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
    run --separate-stderr swift "$SCRIPTS/lib/ed25519-keypair.swift"
    [ "$status" -eq 0 ]
    [[ "$output" =~ $pattern ]] || return 1
    first="$output"
    run --separate-stderr swift "$SCRIPTS/lib/ed25519-keypair.swift"
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
    cp "$SCRIPTS"/lib/*.sh "$ROOT/scripts/lib/"
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
