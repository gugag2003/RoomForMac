#!/usr/bin/env bats
# Checks the disk-image tooling without ever creating, attaching or mounting a real
# disk image: scripts/make-dmg.sh, scripts/lib/dmg.sh, scripts/dsstore-layout.py and
# scripts/make-dmg-layout.sh run against the stand-in hdiutil, diskutil and dmgbuild
# of dmg_stubs.bash, and the committed assets in packaging/dmg are checked as files.
# The fake app comes from make_fake_app (fake_app.bash). Each test gets its own STATE and
# TMPDIR, so "nothing is left attached and no temporary folder remains" is checked
# after every run that matters. The one real-image run is a manual step of the plan
# (Step 11 of the plan's Task 10), not a test.

bats_require_minimum_version 1.5.0

load dmg_stubs
load fake_app

setup_file() {
    # Skips the whole file when clang, codesign, lipo or plutil is missing
    # (Task 9's Interface issue): `skip` cannot work inside $(make_fake_app ...).
    fake_app_require_tools
    FAKE_APP="$(make_fake_app "$BATS_FILE_TMPDIR/app")"
    export FAKE_APP
}

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
    SCRIPTS="$REPO/scripts"
    TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
    STATE="$TMP/state"
    TMPDIR="$TMP/tmp"
    PKG="$TMP/packaging"
    VOLUME_ICON="$TMP/VolumeIcon.icns"
    OUT="$TMP/out/RoomForMac.dmg"
    APP="$FAKE_APP"
    RFM_DMG_RETRY_DELAY=0
    mkdir -p "$TMPDIR" "$PKG"
    write_dmg_stubs "$TMP/stubs"
    python3 "$BATS_TEST_DIRNAME/dsstore_fixture.py" "$PKG/DS_Store"
    printf 'fake tiff\n' > "$PKG/background.tiff"
    printf 'fake icns\n' > "$VOLUME_ICON"
    # Nothing from the developer's or CI's environment may steer a test.
    unset FORMAT RFM_DMG_VOLUME_NAME_OVERRIDE PACKAGING CI STUB_CREATE_BUSY \
        STUB_DETACH_BUSY STUB_DISKUTIL_FAIL STUB_CONVERT_FAIL STUB_FORCE_FS STUB_DROP \
        STUB_APPLICATIONS_DIR STUB_APPLICATIONS_LINK STUB_NO_ICON_FLAG STUB_ALTER \
        STUB_CODESIGN_FAIL STUB_CODESIGN_HANG STUB_ATTACH_FAIL STUB_DETACH_FAIL STUB_PIP_FAIL STUB_DMGBUILD_FAIL STUB_LAYOUT_VOLUME \
        RFM_DMG_KEEP_WORK
    export STATE TMPDIR VOLUME_ICON RFM_DMG_RETRY_DELAY
}

# run_dmg: make-dmg.sh on $APP, into $OUT, with the fixture layout in $PKG.
run_dmg() {
    run --separate-stderr env PACKAGING="$PKG" "$SCRIPTS/make-dmg.sh" "$APP" "$OUT"
}

# assert_clean: no fake image is attached and the script left no temporary folder.
assert_clean() {
    [ "$(attached_count)" -eq 0 ]
    [ -z "$(ls -A "$TMPDIR")" ]
}

@test "--help prints the usage and exits 0" {
    run "$SCRIPTS/make-dmg.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: scripts/make-dmg.sh <RoomForMac.app> <out.dmg>"* ]] || return 1
    [ ! -e "$STATE/calls.log" ]
}

@test "the wrong number of arguments is a usage error" {
    run --separate-stderr "$SCRIPTS/make-dmg.sh"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"error: expected <RoomForMac.app> <out.dmg>"* ]] || return 1
    run --separate-stderr "$SCRIPTS/make-dmg.sh" "$APP" "$OUT" extra
    [ "$status" -eq 2 ]
    [ ! -e "$STATE/calls.log" ]
}

@test "something that is not an app bundle is a usage error" {
    mkdir "$TMP/NotAnApp"
    run --separate-stderr "$SCRIPTS/make-dmg.sh" "$TMP/NotAnApp" "$OUT"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"is not an app bundle"* ]] || return 1
    run --separate-stderr "$SCRIPTS/make-dmg.sh" "$TMP/Missing.app" "$OUT"
    [ "$status" -eq 2 ]
    mkdir -p "$TMP/folder"
    run --separate-stderr "$SCRIPTS/make-dmg.sh" "$APP" "$TMP/folder"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"is a folder"* ]] || return 1
    [ ! -e "$STATE/calls.log" ]
}

@test "FORMAT=XYZ is a usage error and runs no tool" {
    FORMAT=XYZ
    export FORMAT
    run_dmg
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"error: FORMAT must be ULMO, ULFO or UDZO, not XYZ"* ]] || return 1
    [ ! -e "$STATE/calls.log" ]
    [ ! -e "$OUT" ]
}

@test "it builds an image whose root, file system, volume icon and format are right" {
    run_dmg
    [ "$status" -eq 0 ]
    [ -f "$OUT" ]
    store="$(image_store "$OUT")"
    [ "$(image_field "$OUT" volname)" = RoomForMac ]
    [ "$(image_field "$OUT" fs)" = "HFS+" ]
    [ "$(image_field "$OUT" format)" = ULMO ]
    [ "$(LC_ALL=C ls -A "$store" | tr '\n' ' ')" = ".DS_Store .VolumeIcon.icns .background.tiff Applications RoomForMac.app " ]
    [ -d "$store/RoomForMac.app" ]
    [ -L "$store/Applications" ]
    [ "$(readlink "$store/Applications")" = /Applications ]
    cmp "$store/.DS_Store" "$PKG/DS_Store"
    cmp "$store/.background.tiff" "$PKG/background.tiff"
    cmp "$store/.VolumeIcon.icns" "$VOLUME_ICON"
    # kHasCustomIcon: the flag word at offset 8 of the volume's Finder info.
    hex="$(xattr -px com.apple.FinderInfo "$store" | tr -d ' \n')"
    [ "${#hex}" -eq 64 ]
    [ "${hex:16:4}" = 0400 ]
    # The copy of the app inside the image is still sound (a real codesign).
    /usr/bin/codesign --verify --deep --strict "$store/RoomForMac.app"
    assert_clean
}

@test "stdout is the path, the size and the SHA-256, and nothing else" {
    run_dmg
    [ "$status" -eq 0 ]
    [ "$output" = "$OUT $(wc -c < "$OUT" | tr -d ' ') $(shasum -a 256 "$OUT" | cut -d' ' -f1)" ]
    [ "${#output}" -gt 100 ]
    [[ "$stderr" == *"==> checking the finished image"* ]] || return 1
}

@test "the tools run in order: create, attach read-write, detach, compress, attach read-only, check, detach" {
    run_dmg
    [ "$status" -eq 0 ]
    order="$(awk '$1 == "hdiutil" { print $1, $2 } $1 == "diskutil" && $2 == "image" { print $1, $2, $3, $4 } $1 == "diskutil" && $2 == "info" { print $1, $2 }' "$STATE/calls.log")"
    [ "$order" = "hdiutil create
hdiutil attach
hdiutil detach
diskutil image create from
hdiutil attach
diskutil info
hdiutil detach" ]
    # The app is verified before it is staged and again inside the image.
    [ "$(calls_to codesign)" -eq 2 ]
    [ "$(grep '^codesign' "$STATE/calls.log" | sed -n 1p)" = "codesign --verify --deep --strict $APP" ]
    [[ "$(grep '^codesign' "$STATE/calls.log" | sed -n 2p)" == "codesign --verify --deep --strict $TMPDIR/rfm-dmg."*"/mount-check/RoomForMac.app" ]]
}

@test "every attach is -nobrowse -noautoopen with an explicit mount point, read-write once and then read-only" {
    run_dmg
    [ "$status" -eq 0 ]
    attaches="$(grep '^hdiutil attach' "$STATE/calls.log")"
    [ "$(printf '%s\n' "$attaches" | wc -l | tr -d ' ')" -eq 2 ]
    while IFS= read -r line; do
        [[ "$line" == *" -nobrowse "* ]] || return 1
        [[ "$line" == *" -noautoopen "* ]] || return 1
        [[ "$line" == *" -mountpoint $TMPDIR/rfm-dmg."* ]] || return 1
    done <<< "$attaches"
    [[ "$(printf '%s\n' "$attaches" | sed -n 1p)" == *" -readwrite "* ]] || return 1
    [[ "$(printf '%s\n' "$attaches" | sed -n 2p)" == *" -readonly "* ]]
}

@test "the read-write image is HFS+ and is made from the staged folder" {
    run_dmg
    [ "$status" -eq 0 ]
    create="$(grep '^hdiutil create' "$STATE/calls.log")"
    [[ "$create" == *" -volname RoomForMac "* ]] || return 1
    [[ "$create" == *" -fs HFS+ "* ]] || return 1
    [[ "$create" == *" -format UDRW "* ]] || return 1
    [[ "$create" == *" -srcfolder $TMPDIR/rfm-dmg."*"/stage "* ]]
}

@test "FORMAT picks the compression: ULFO and UDZO reach diskutil and the image" {
    for format in ULFO UDZO; do
        rm -f "$OUT"
        run --separate-stderr env FORMAT="$format" PACKAGING="$PKG" "$SCRIPTS/make-dmg.sh" "$APP" "$OUT"
        [ "$status" -eq 0 ]
        [ "$(image_field "$OUT" format)" = "$format" ]
        [[ "$(grep '^diskutil image' "$STATE/calls.log" | tail -n 1)" == *" --format $format "* ]] || return 1
    done
}

@test "when diskutil cannot compress, hdiutil convert does, with the same format" {
    STUB_DISKUTIL_FAIL=1
    export STUB_DISKUTIL_FAIL
    run_dmg
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"trying hdiutil convert"* ]] || return 1
    [ "$(calls_to 'hdiutil convert')" -eq 1 ]
    [[ "$(grep '^hdiutil convert' "$STATE/calls.log")" == *" -format ULMO "* ]] || return 1
    [ "$(image_field "$OUT" format)" = ULMO ]
    assert_clean
}

@test "when both compressors fail, nothing is written and nothing stays attached" {
    STUB_DISKUTIL_FAIL=1
    STUB_CONVERT_FAIL=1
    export STUB_DISKUTIL_FAIL STUB_CONVERT_FAIL
    run_dmg
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"error: could not compress the image"* ]] || return 1
    [ ! -e "$OUT" ]
    assert_clean
}

@test "hdiutil create is retried on Resource busy, up to 5 times" {
    STUB_CREATE_BUSY=2
    export STUB_CREATE_BUSY
    run_dmg
    [ "$status" -eq 0 ]
    [ "$(calls_to 'hdiutil create')" -eq 3 ]
    assert_clean
}

@test "hdiutil create that stays busy fails after 5 attempts" {
    STUB_CREATE_BUSY=9
    export STUB_CREATE_BUSY
    run_dmg
    [ "$status" -eq 1 ]
    [ "$(calls_to 'hdiutil create')" -eq 5 ]
    [[ "$stderr" == *"Resource busy"* ]] || return 1
    [[ "$stderr" == *"error: hdiutil could not create the image"* ]] || return 1
    [ ! -e "$OUT" ]
    assert_clean
}

@test "a detach that is busy is retried, then forced as the last resort" {
    STUB_DETACH_BUSY=2
    export STUB_DETACH_BUSY
    run_dmg
    [ "$status" -eq 0 ]
    # Two busy answers and one success for the first image, one success for the second.
    [ "$(calls_to 'hdiutil detach')" -eq 4 ]
    [ "$(calls_to 'hdiutil detach -quiet -force')" -eq 0 ]
    assert_clean
    rm -f "$OUT"
    rm -f "$STATE/calls.log" "$STATE/detaches"
    STUB_DETACH_BUSY=99
    export STUB_DETACH_BUSY
    run_dmg
    [ "$status" -eq 0 ]
    [ "$(calls_to 'hdiutil detach -quiet -force')" -eq 2 ]
    assert_clean
}

@test "a layout made for another volume name is refused before any tool runs" {
    RFM_DMG_VOLUME_NAME_OVERRIDE=Other
    export RFM_DMG_VOLUME_NAME_OVERRIDE
    run_dmg
    [ "$status" -eq 1 ]
    [[ "$stderr" == *'was made for the volume "RoomForMac", not "Other"'* ]] || return 1
    [ ! -e "$STATE/calls.log" ]
    [ ! -e "$OUT" ]
}

@test "the expected volume name is RFM_DMG_VOLUME_NAME from the distribution config" {
    # No override here: a layout made for another name is refused against the
    # name in Config/Distribution.xcconfig.
    python3 "$BATS_TEST_DIRNAME/dsstore_fixture.py" "$PKG/DS_Store" --volume Other
    run_dmg
    [ "$status" -eq 1 ]
    [[ "$stderr" == *'was made for the volume "Other", not "RoomForMac"'* ]] || return 1
    [ ! -e "$STATE/calls.log" ]
}

@test "an app with another name has no icon position and is refused" {
    ditto "$FAKE_APP" "$TMP/Other.app"
    APP="$TMP/Other.app"
    run_dmg
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"has no icon position for Other.app"* ]] || return 1
    [ ! -e "$STATE/calls.log" ]
    [ ! -e "$OUT" ]
}

@test "a layout without a position for Applications is refused" {
    python3 "$BATS_TEST_DIRNAME/dsstore_fixture.py" "$PKG/DS_Store" --no-icons --icon RoomForMac.app 165 120
    run_dmg
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"has no icon position for Applications"* ]] || return 1
    [ ! -e "$STATE/calls.log" ]
}

@test "a layout that draws another background, or none, is refused" {
    python3 "$BATS_TEST_DIRNAME/dsstore_fixture.py" "$PKG/DS_Store" --background /background.tiff
    run_dmg
    [ "$status" -eq 1 ]
    [[ "$stderr" == *'draws the background "/background.tiff", not "/.background.tiff"'* ]] || return 1
    python3 "$BATS_TEST_DIRNAME/dsstore_fixture.py" "$PKG/DS_Store" --no-alias
    run_dmg
    [ "$status" -eq 1 ]
    [[ "$stderr" == *'was made for the volume "", not "RoomForMac"'* ]] || return 1
    [ ! -e "$STATE/calls.log" ]
}

@test "a file that is not a .DS_Store is refused with the reader's message" {
    head -c 100 /dev/zero > "$PKG/DS_Store"
    run_dmg
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"no Bud1 header"* ]] || return 1
    [ ! -e "$STATE/calls.log" ]
}

@test "a missing layout, background or volume icon is refused" {
    rm "$PKG/background.tiff"
    run_dmg
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"background.tiff does not exist"* ]] || return 1
    printf 'fake tiff\n' > "$PKG/background.tiff"
    rm "$VOLUME_ICON"
    run_dmg
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"VolumeIcon.icns does not exist"* ]] || return 1
    [ ! -e "$STATE/calls.log" ]
}

@test "an app that does not pass strict verification never reaches the image" {
    ditto "$FAKE_APP" "$TMP/broken/RoomForMac.app"
    printf '\n' >> "$TMP/broken/RoomForMac.app/Contents/Info.plist"
    APP="$TMP/broken/RoomForMac.app"
    run_dmg
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"does not pass codesign --verify --deep --strict"* ]] || return 1
    [ "$(calls_to 'hdiutil')" -eq 0 ]
    [ ! -e "$OUT" ]
    assert_clean
}

# Each check after compression must be able to fail. The stub damages the compressed
# image in one way per run, as a lossy pipeline would.
@test "the finished image is refused when it lacks a file it must hold" {
    for name in RoomForMac.app .background.tiff .DS_Store .VolumeIcon.icns; do
        STUB_DROP="$name" run --separate-stderr env PACKAGING="$PKG" "$SCRIPTS/make-dmg.sh" "$APP" "$OUT"
        [ "$status" -eq 1 ]
        [[ "$stderr" == *"error: the image has no $name"* ]] || return 1
        [ ! -e "$OUT" ]
        assert_clean
    done
}

@test "the finished image is refused when Applications is a folder, or a link to somewhere else" {
    STUB_APPLICATIONS_DIR=1
    export STUB_APPLICATIONS_DIR
    run_dmg
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"Applications in the image is not a link to /Applications"* ]] || return 1
    unset STUB_APPLICATIONS_DIR
    STUB_APPLICATIONS_LINK=/Users
    export STUB_APPLICATIONS_LINK
    run_dmg
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"Applications in the image is not a link to /Applications"* ]] || return 1
    [ ! -e "$OUT" ]
    assert_clean
}

@test "the finished image is refused when a hidden file differs from the committed one" {
    for name in .DS_Store .background.tiff .VolumeIcon.icns; do
        STUB_ALTER="$name" run --separate-stderr env PACKAGING="$PKG" "$SCRIPTS/make-dmg.sh" "$APP" "$OUT"
        [ "$status" -eq 1 ]
        [[ "$stderr" == *"error: $name in the image differs from "* ]] || return 1
        [ ! -e "$OUT" ]
        assert_clean
    done
}

@test "the finished image is refused when the volume lost its custom-icon flag" {
    STUB_NO_ICON_FLAG=1
    export STUB_NO_ICON_FLAG
    run_dmg
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"does not carry the custom-icon flag"* ]] || return 1
    [ ! -e "$OUT" ]
    assert_clean
}

@test "the finished image is refused when it is not HFS+" {
    STUB_FORCE_FS=APFS
    export STUB_FORCE_FS
    run_dmg
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"error: the image is not HFS+"* ]] || return 1
    [ ! -e "$OUT" ]
    assert_clean
}

@test "the finished image is refused when the app inside fails strict verification" {
    STUB_CODESIGN_FAIL=1
    export STUB_CODESIGN_FAIL
    run_dmg
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"inside the image does not pass codesign --verify --deep --strict"* ]] || return 1
    [ ! -e "$OUT" ]
    assert_clean
}

@test "an existing output image is replaced only by a finished one" {
    mkdir -p "$TMP/out"
    printf 'old image\n' > "$OUT"
    STUB_NO_ICON_FLAG=1
    export STUB_NO_ICON_FLAG
    run_dmg
    [ "$status" -eq 1 ]
    [ "$(cat "$OUT")" = "old image" ]
    unset STUB_NO_ICON_FLAG
    run_dmg
    [ "$status" -eq 0 ]
    [ "$(head -n 1 "$OUT")" = FAKE-DMG ]
}

@test "the scripts reach hdiutil, diskutil and codesign only through their variables" {
    # A bare or full-path call would bypass the stubs and touch a real image.
    count="$(grep -cE '/usr/(bin|sbin)/(hdiutil|diskutil|codesign)' "$SCRIPTS/make-dmg.sh")"
    [ "$count" -eq 3 ]
    grep -E '/usr/(bin|sbin)/(hdiutil|diskutil|codesign)' "$SCRIPTS/make-dmg.sh" | grep -vE '^(HDIUTIL|DISKUTIL|CODESIGN)="\$\{(HDIUTIL|DISKUTIL|CODESIGN):-/usr/(bin|sbin)/[a-z]+\}"$' && return 1
    [ "$(grep -cE '/usr/(bin|sbin)/(hdiutil|diskutil)' "$SCRIPTS/lib/dmg.sh")" -eq 0 ]
    [ "$(grep -cE '/usr/(bin|sbin)/hdiutil' "$SCRIPTS/make-dmg-layout.sh")" -eq 1 ]
}

@test "the scripts never script Finder, use makehybrid or SetFile, or run privileged" {
    for file in make-dmg.sh make-dmg-layout.sh lib/dmg.sh; do
        [ -f "$SCRIPTS/$file" ]
        matches="$(grep -vE '^[[:space:]]*#' "$SCRIPTS/$file" | grep -cE 'osascript|AppleScript|makehybrid|SetFile|sudo|tell application|com\.apple\.finder' || true)"
        [ "$matches" -eq 0 ]
    done
}

@test "the committed layout and background pass make-dmg.sh's own guard" {
    # The real packaging/dmg files, with the fake tools: this fails if the committed
    # DS_Store was made for another volume, or names another background or item.
    run --separate-stderr env "$SCRIPTS/make-dmg.sh" "$APP" "$OUT"
    [ "$status" -eq 0 ]
    store="$(image_store "$OUT")"
    cmp "$store/.DS_Store" "$REPO/packaging/dmg/DS_Store"
    cmp "$store/.background.tiff" "$REPO/packaging/dmg/background.tiff"
}

# --- dsstore-layout.py --------------------------------------------------------

@test "dsstore-layout.py prints the volume, background, window and icons" {
    run python3 "$SCRIPTS/dsstore-layout.py" "$PKG/DS_Store"
    [ "$status" -eq 0 ]
    [ "$output" = '{"volume": "RoomForMac", "background": "/.background.tiff", "window": "{{200, 120}, {660, 400}}", "icons": {"Applications": [495, 120], "RoomForMac.app": [165, 120]}}' ]
}

@test "dsstore-layout.py follows child blocks of a two-level record tree" {
    python3 "$BATS_TEST_DIRNAME/dsstore_fixture.py" "$TMP/tree" --tree
    run python3 "$SCRIPTS/dsstore-layout.py" "$TMP/tree"
    [ "$status" -eq 0 ]
    [ "$output" = '{"volume": "RoomForMac", "background": "/.background.tiff", "window": "{{200, 120}, {660, 400}}", "icons": {"Applications": [495, 120], "RoomForMac.app": [165, 120]}}' ]
}

@test "dsstore-layout.py reports the volume the alias names, including accented letters" {
    python3 "$BATS_TEST_DIRNAME/dsstore_fixture.py" "$TMP/other" --volume "RoomForMac 1"
    run python3 "$SCRIPTS/dsstore-layout.py" "$TMP/other"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"volume": "RoomForMac 1"'* ]] || return 1
    python3 "$BATS_TEST_DIRNAME/dsstore_fixture.py" "$TMP/accent" --volume "Café Mac"
    run python3 "$SCRIPTS/dsstore-layout.py" "$TMP/accent"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | python3 -c 'import json, sys; sys.exit(json.load(sys.stdin)["volume"] != "Caf\xe9 Mac")'
}

@test "dsstore-layout.py prefers the alias's Unicode volume name over its Mac Roman one" {
    # The star is not in Mac Roman, so only the Unicode tag can carry it.
    python3 "$BATS_TEST_DIRNAME/dsstore_fixture.py" "$TMP/star" --volume "Room ★"
    run python3 "$SCRIPTS/dsstore-layout.py" "$TMP/star"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | python3 -c 'import json, sys; sys.exit(json.load(sys.stdin)["volume"] != "Room \u2605")'
}

@test "dsstore-layout.py reads a background path and icon positions it was not written with" {
    python3 "$BATS_TEST_DIRNAME/dsstore_fixture.py" "$TMP/custom" --background /.other/pic.png --no-icons --icon "One.app" 10 20 --icon "Two" 300 400
    run python3 "$SCRIPTS/dsstore-layout.py" "$TMP/custom"
    [ "$status" -eq 0 ]
    [ "$output" = '{"volume": "RoomForMac", "background": "/.other/pic.png", "window": "{{200, 120}, {660, 400}}", "icons": {"One.app": [10, 20], "Two": [300, 400]}}' ]
}

@test "dsstore-layout.py --records adds every record, values decoded" {
    run python3 "$SCRIPTS/dsstore-layout.py" "$PKG/DS_Store" --records
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | grep -o '"code": "Iloc"' | wc -l | tr -d ' ')" -eq 2 ]
    [[ "$output" == *'"code": "bwsp"'* ]] || return 1
    [[ "$output" == *'"code": "icvp"'* ]] || return 1
    [[ "$output" == *'"code": "vSrn", "type": "long", "value": 1'* ]] || return 1
    [[ "$output" == *'"WindowBounds": "{{200, 120}, {660, 400}}"'* ]]
}

@test "dsstore-layout.py gives empty fields for a layout with no background alias or window" {
    python3 "$BATS_TEST_DIRNAME/dsstore_fixture.py" "$TMP/bare" --no-alias --no-icons
    run python3 "$SCRIPTS/dsstore-layout.py" "$TMP/bare"
    [ "$status" -eq 0 ]
    [ "$output" = '{"volume": "", "background": "", "window": "{{200, 120}, {660, 400}}", "icons": {}}' ]
}

@test "dsstore-layout.py refuses files it cannot read, and changes nothing" {
    before="$(shasum -a 256 "$PKG/DS_Store")"
    head -c 100 /dev/zero > "$TMP/zeros"
    run --separate-stderr python3 "$SCRIPTS/dsstore-layout.py" "$TMP/zeros"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ "$stderr" == *"error: $TMP/zeros: not a .DS_Store file (no Bud1 header)"* ]] || return 1
    head -c 6000 "$PKG/DS_Store" > "$TMP/short"
    run --separate-stderr python3 "$SCRIPTS/dsstore-layout.py" "$TMP/short"
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"a block lies outside the file"* ]] || return 1
    run --separate-stderr python3 "$SCRIPTS/dsstore-layout.py" "$TMP/missing"
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"No such file"* ]] || return 1
    python3 - "$PKG/DS_Store" "$TMP/odd" << 'PY'
import sys

data = open(sys.argv[1], "rb").read()
assert b"vSrnlong" in data
open(sys.argv[2], "wb").write(data.replace(b"vSrnlong", b"vSrnzzzz"))
PY
    run --separate-stderr python3 "$SCRIPTS/dsstore-layout.py" "$TMP/odd"
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"unknown record type 'zzzz'"* ]] || return 1
    [ "$(shasum -a 256 "$PKG/DS_Store")" = "$before" ]
}

@test "dsstore-layout.py: usage errors exit 2" {
    run python3 "$SCRIPTS/dsstore-layout.py"
    [ "$status" -eq 2 ]
    run python3 "$SCRIPTS/dsstore-layout.py" --bogus
    [ "$status" -eq 2 ]
    run python3 "$SCRIPTS/dsstore-layout.py" "$PKG/DS_Store" "$PKG/DS_Store"
    [ "$status" -eq 2 ]
    run python3 "$SCRIPTS/dsstore-layout.py" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: dsstore-layout.py <DS_Store> [--records]"* ]]
}

@test "the committed DS_Store names the volume, the hidden background and both icons" {
    # Positions are not pinned here: Option B in packaging/dmg/README.md places them by hand.
    run --separate-stderr python3 "$SCRIPTS/dsstore-layout.py" "$REPO/packaging/dmg/DS_Store"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"volume": "RoomForMac"'* ]] || return 1
    [[ "$output" == *'"background": "/.background.tiff"'* ]] || return 1
    [[ "$output" == *'"RoomForMac.app": ['* ]] || return 1
    [[ "$output" == *'"Applications": ['* ]]
}

# --- make-dmg-layout.sh -------------------------------------------------------

# make_layout_repo: a throwaway copy of what make-dmg-layout.sh reads and writes, so
# no test can replace the committed packaging/dmg/DS_Store.
make_layout_repo() {
    LAY="$TMP/layrepo"
    mkdir -p "$LAY/scripts/lib" "$LAY/Config" "$LAY/packaging/dmg" "$TMP/volumes"
    cp "$SCRIPTS/make-dmg-layout.sh" "$SCRIPTS/dsstore-layout.py" "$LAY/scripts/"
    cp "$SCRIPTS/lib/dmg.sh" "$SCRIPTS/lib/distribution.sh" "$LAY/scripts/lib/"
    cp "$REPO/Config/Distribution.xcconfig" "$LAY/Config/"
    cp "$REPO/packaging/dmg/dmgbuild-settings.py" "$REPO/packaging/dmg/dmgbuild-requirements.txt" "$LAY/packaging/dmg/"
    printf 'png\n' > "$LAY/packaging/dmg/background.png"
    printf 'png2x\n' > "$LAY/packaging/dmg/background@2x.png"
    printf 'sentinel layout\n' > "$LAY/packaging/dmg/DS_Store"
    write_dmgbuild_stubs "$TMP/pystubs"
    DMGBUILD_VENV="$TMP/venv"
    VOLUMES_DIR="$TMP/volumes"
    export DMGBUILD_VENV VOLUMES_DIR
}

run_layout() {
    run --separate-stderr env -u CI "$LAY/scripts/make-dmg-layout.sh" "$@"
}

@test "make-dmg-layout.sh --help prints the usage and exits 0" {
    make_layout_repo
    run_layout --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: scripts/make-dmg-layout.sh [--app <RoomForMac.app>] [--help]"* ]] || return 1
    [ ! -e "$STATE/calls.log" ]
}

@test "make-dmg-layout.sh refuses to run in CI, with a bad flag, or with a misnamed app" {
    make_layout_repo
    run --separate-stderr env CI=true "$LAY/scripts/make-dmg-layout.sh"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"never runs in CI"* ]] || return 1
    run_layout --force
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"unknown argument: --force"* ]] || return 1
    run_layout --app
    [ "$status" -eq 2 ]
    mkdir "$TMP/Other.app"
    run_layout --app "$TMP/Other.app"
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"--app must be named RoomForMac.app"* ]] || return 1
    [ ! -e "$STATE/calls.log" ]
    [ "$(cat "$LAY/packaging/dmg/DS_Store")" = "sentinel layout" ]
}

@test "make-dmg-layout.sh refuses while a volume with the image's name is mounted" {
    make_layout_repo
    mkdir "$VOLUMES_DIR/RoomForMac"
    run_layout
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"a volume named RoomForMac is mounted; eject it first"* ]] || return 1
    [ ! -e "$STATE/calls.log" ]
}

@test "make-dmg-layout.sh installs the pinned packages with hashes, runs dmgbuild and keeps its DS_Store" {
    make_layout_repo
    run_layout
    [ "$status" -eq 0 ]
    # pip: only with hashes, from the committed requirements file.
    pip="$(grep '^pip ' "$STATE/calls.log")"
    [[ "$pip" == *" --require-hashes -r $LAY/packaging/dmg/dmgbuild-requirements.txt" ]] || return 1
    # dmgbuild: the committed settings, the app and background as defines, the volume name.
    build="$(grep '^dmgbuild ' "$STATE/calls.log")"
    [[ "$build" == "dmgbuild -s $LAY/packaging/dmg/dmgbuild-settings.py -D app="*"/RoomForMac.app -D background=$LAY/packaging/dmg/background.png RoomForMac "*"/layout.dmg" ]] || return 1
    # The layout dmgbuild wrote replaced the sentinel, and passes the checks.
    run python3 "$LAY/scripts/dsstore-layout.py" "$LAY/packaging/dmg/DS_Store"
    [ "$status" -eq 0 ]
    [ "$output" = '{"volume": "RoomForMac", "background": "/.background.tiff", "window": "{{200, 120}, {660, 400}}", "icons": {"Applications": [495, 120], "RoomForMac.app": [165, 120]}}' ]
    [ ! -e "$LAY/packaging/dmg/DS_Store.new" ]
    # The throwaway image was attached only read-only, hidden, and detached again.
    [ "$(calls_to 'hdiutil attach')" -eq 1 ]
    [[ "$(grep '^hdiutil attach' "$STATE/calls.log")" == *" -nobrowse -noautoopen -readonly "* ]] || return 1
    assert_clean
}

@test "make-dmg-layout.sh keeps its temporary folder when RFM_DMG_KEEP_WORK is set" {
    make_layout_repo
    run --separate-stderr env -u CI RFM_DMG_KEEP_WORK=1 "$LAY/scripts/make-dmg-layout.sh"
    [ "$status" -eq 0 ]
    kept="$(printf '%s\n' "$stderr" | sed -n 's/^kept //p')"
    [ -f "$kept/DS_Store" ]
    [ -f "$kept/layout.dmg" ]
    [ "$(attached_count)" -eq 0 ]
    unset RFM_DMG_KEEP_WORK
    run_layout
    [ "$status" -eq 0 ]
    [ -d "$kept" ]
}

@test "make-dmg-layout.sh keeps the committed DS_Store when dmgbuild's layout is for another volume" {
    make_layout_repo
    STUB_LAYOUT_VOLUME="RoomForMac 1"
    export STUB_LAYOUT_VOLUME
    run_layout
    [ "$status" -eq 1 ]
    [[ "$stderr" == *'was made for the volume "RoomForMac 1", not "RoomForMac"'* ]] || return 1
    [ "$(cat "$LAY/packaging/dmg/DS_Store")" = "sentinel layout" ]
    assert_clean
}

@test "make-dmg-layout.sh stops when pip or dmgbuild fails, and keeps the committed DS_Store" {
    make_layout_repo
    STUB_PIP_FAIL=1
    export STUB_PIP_FAIL
    run_layout
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"pip could not install the pinned packages"* ]] || return 1
    [ "$(calls_to 'dmgbuild')" -eq 0 ]
    unset STUB_PIP_FAIL
    STUB_DMGBUILD_FAIL=1
    export STUB_DMGBUILD_FAIL
    run_layout
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"dmgbuild failed"* ]] || return 1
    [ "$(cat "$LAY/packaging/dmg/DS_Store")" = "sentinel layout" ]
    assert_clean
}

# --- the committed assets in packaging/dmg ------------------------------------

# sips_value FILE KEY: one number from `sips -g`.
sips_value() {
    sips -g "$2" "$1" | awk -v key="$2:" '$1 == key { print $2 }'
}

@test "the background pictures have the sizes and resolutions the window needs" {
    dir="$REPO/packaging/dmg"
    [ "$(sips_value "$dir/background.png" pixelWidth)" = 660 ]
    [ "$(sips_value "$dir/background.png" pixelHeight)" = 400 ]
    [ "$(sips_value "$dir/background.png" dpiWidth)" = 72.000 ]
    [ "$(sips_value "$dir/background@2x.png" pixelWidth)" = 1320 ]
    [ "$(sips_value "$dir/background@2x.png" pixelHeight)" = 800 ]
    [ "$(sips_value "$dir/background@2x.png" dpiWidth)" = 144.000 ]
}

@test "background.tiff holds the 1x and 2x pictures" {
    run tiffutil -info "$REPO/packaging/dmg/background.tiff"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -c '^Directory at')" -eq 2 ]
    [[ "$output" == *"Image Width: 660 Image Length: 400"* ]] || return 1
    [[ "$output" == *"Resolution: 72, 72"* ]] || return 1
    [[ "$output" == *"Image Width: 1320 Image Length: 800"* ]] || return 1
    [[ "$output" == *"Resolution: 144, 144"* ]]
}

@test "the background script carries the exact instructions and no Terminal advice" {
    file="$SCRIPTS/make-dmg-background.swift"
    while IFS= read -r line; do
        grep -qF -- "\"$line\"" "$file" || {
            echo "missing from $file: $line" >&2
            return 1
        }
    done << 'COPY'
First launch: macOS can't check apps from outside the App Store. Do this once:
1. Open RoomForMac. When macOS says “RoomForMac” Not Opened, click Done.
2. Open System Settings › Privacy & Security. Under Security, click Open Anyway.
3. Click Open Anyway again, then enter your login password.
COPY
    [ "$(grep -ciE 'terminal|xattr|spctl|sudo|mole|cleanmymac' "$file")" -eq 0 ]
}

@test "the background's geometry is the settings file's: window size, icon size and icon centres" {
    run python3 - "$SCRIPTS/make-dmg-background.swift" "$REPO/packaging/dmg/dmgbuild-settings.py" << 'PY'
import re
import sys

swift = open(sys.argv[1]).read()


def const(name):
    return int(re.search(r"static let %s: CGFloat = (\d+)\b" % name, swift).group(1))


namespace = {"defines": {"app": "/x/RoomForMac.app"}}
exec(compile(open(sys.argv[2]).read(), sys.argv[2], "exec"), namespace)
(left, top), (width, height) = namespace["window_rect"]
assert (width, height) == (const("width"), const("height")), "window size"
assert namespace["icon_size"] == const("iconSize"), "icon size"
assert namespace["icon_locations"]["RoomForMac.app"] == (const("appX"), const("iconY")), "app position"
assert namespace["icon_locations"]["Applications"] == (const("applicationsX"), const("iconY")), "Applications position"
print("geometry-ok")
PY
    [ "$status" -eq 0 ]
    [ "$output" = geometry-ok ]
}

@test "the dmgbuild settings describe the window make-dmg.sh expects" {
    run python3 - "$REPO/packaging/dmg/dmgbuild-settings.py" << 'PY'
import json
import sys

namespace = {"defines": {"app": "/x/RoomForMac.app", "background": "/x/background.png"}}
exec(compile(open(sys.argv[1]).read(), sys.argv[1], "exec"), namespace)
keys = ["filesystem", "files", "symlinks", "background", "default_view", "icon_size",
        "show_toolbar", "show_sidebar", "show_status_bar", "show_pathbar", "text_size"]
print(json.dumps({key: namespace[key] for key in keys}, sort_keys=True))
PY
    [ "$status" -eq 0 ]
    [ "$output" = '{"background": "/x/background.png", "default_view": "icon-view", "files": ["/x/RoomForMac.app"], "filesystem": "HFS+", "icon_size": 128, "show_pathbar": false, "show_sidebar": false, "show_status_bar": false, "show_toolbar": false, "symlinks": {"Applications": "/Applications"}, "text_size": 12}' ]
    run --separate-stderr python3 -c 'exec(open("'"$REPO"'/packaging/dmg/dmgbuild-settings.py").read(), {"defines": {}})'
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"pass -D app=<path to RoomForMac.app>"* ]]
}

@test "dmgbuild-requirements.txt pins dmgbuild, ds_store and mac_alias exactly, each with sha256 hashes" {
    run python3 - "$REPO/packaging/dmg/dmgbuild-requirements.txt" << 'PY'
import re
import sys

text = open(sys.argv[1]).read().replace("\\\n", " ")
pins = {}
for line in text.splitlines():
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    name, version = re.match(r"^([A-Za-z0-9_.-]+)==([0-9.]+)\s", line + " ").groups()
    hashes = re.findall(r"--hash=sha256:([0-9a-f]{64})(?=\s|$)", line)
    assert hashes, name + " has no sha256 hash"
    assert re.sub(r"--hash=sha256:[0-9a-f]{64}|\s", "", line) == name + "==" + version, line
    pins[name.lower().replace("-", "_")] = version
assert pins == {"dmgbuild": "1.6.7", "ds_store": "1.3.3", "mac_alias": "2.2.3"}, pins
print("requirements-ok")
PY
    [ "$status" -eq 0 ]
    [ "$output" = requirements-ok ]
}

@test "packaging/dmg/README.md covers regenerating, Option B and the names that never change" {
    file="$REPO/packaging/dmg/README.md"
    for phrase in "Option A" "Option B" "scripts/make-dmg-background.swift" "tiffutil -cathidpicheck" \
        "scripts/make-dmg-layout.sh" "/.background.tiff" "never change" "RoomForMac"; do
        grep -qF -- "$phrase" "$file" || {
            echo "README.md does not mention: $phrase" >&2
            return 1
        }
    done
}

@test "the dmgbuild venv falls under the ignored build folder" {
    git -C "$REPO" check-ignore -q build/dmgbuild-venv
}

@test "a failed attach still removes the temporary folder" {
    local mode
    for mode in readwrite readonly; do
        STUB_ATTACH_FAIL="$mode"
        export STUB_ATTACH_FAIL
        run_dmg
        [ "$status" -eq 1 ]
        [[ "$stderr" == *"could not attach"* ]] || return 1
        [[ "$stderr" != *"leaving"* ]] || return 1
        [ ! -e "$OUT" ]
        assert_clean
    done
}

@test "a TERM in the middle of a run detaches the image and removes the temporary folder" {
    STUB_CODESIGN_HANG=1
    export STUB_CODESIGN_HANG
    PACKAGING="$PKG" "$SCRIPTS/make-dmg.sh" "$APP" "$OUT" > /dev/null 2>&1 &
    local pid=$! tries=0
    # Wait (at most about 20 s) until the script is inside the check mount.
    while [ ! -s "$STATE/hung.pid" ] && [ "$tries" -lt 200 ]; do
        tries=$((tries + 1))
        sleep 0.1
    done
    [ -s "$STATE/hung.pid" ]
    [ "$(attached_count)" -eq 1 ]
    kill -TERM "$pid"
    kill -TERM "$(cat "$STATE/hung.pid")"
    local status=0
    wait "$pid" || status=$?
    [ "$status" -ne 0 ]
    [ ! -e "$OUT" ]
    assert_clean
}

@test "when even the forced detach fails, the temporary folder is kept and the script says so" {
    STUB_DETACH_FAIL=1
    export STUB_DETACH_FAIL
    run_dmg
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"warning: could not detach "*"; leaving "*" in place"* ]] || return 1
    [ "$(attached_count)" -ge 1 ]
    [ -n "$(ls -A "$TMPDIR")" ]
    [ ! -e "$OUT" ]
}
