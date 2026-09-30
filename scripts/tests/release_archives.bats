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
