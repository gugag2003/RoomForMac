#!/usr/bin/env bats
# Checks scripts/prepare-sparkle.sh and scripts/lib/sparkle.sh without Xcode, a
# real Sparkle or a real signature. Each test builds a fake Sparkle.framework in
# its own folder and runs the script with the build variables Xcode sets and a
# stub on the CODESIGN variable. The stub logs each call as one line, arguments
# separated by tabs, to $STATE/codesign.log, and fails while the XPC services are
# still in the framework: signing before deleting them would seal a framework
# that is then changed. HOME points into the test folder, so nothing here reads
# the real home or a real Sparkle download.

setup_file() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export ROOT
}

setup() {
    T="$BATS_TEST_TMPDIR"
    BUILD="$T/Build"
    FRAMEWORKS_FOLDER_PATH="RoomForMac.app/Contents/Frameworks"
    FRAMEWORK="$BUILD/$FRAMEWORKS_FOLDER_PATH/Sparkle.framework"
    STATE="$T/state"
    mkdir -p "$STATE" "$T/home"
    : > "$STATE/codesign.log"
    export FRAMEWORK STATE
    make_framework
    cat > "$T/codesign" << 'STUB'
#!/bin/bash
# codesign(1) stand-in: one tab-separated line per call.
set -euo pipefail
if [[ -e "$FRAMEWORK/Versions/B/XPCServices" ]]; then
    echo "stub codesign: XPCServices is still in the framework" >&2
    exit 1
fi
(
    IFS=$'\t'
    printf '%s\n' "$*"
) >> "$STATE/codesign.log"
STUB
    chmod +x "$T/codesign"
}

# The layout of Sparkle 2.10.0's framework: Versions/B, the Current and
# top-level symlinks, Updater.app, Autoupdate and two XPC services.
make_framework() {
    local b="$FRAMEWORK/Versions/B"
    mkdir -p "$b/Updater.app/Contents/MacOS" "$b/Resources" "$b/_CodeSignature" \
        "$b/XPCServices/Installer.xpc/Contents/MacOS" "$b/XPCServices/Downloader.xpc/Contents/MacOS"
    : > "$b/Sparkle"
    : > "$b/Autoupdate"
    : > "$b/Updater.app/Contents/MacOS/Updater"
    : > "$b/Resources/Info.plist"
    : > "$b/_CodeSignature/CodeResources"
    : > "$b/XPCServices/Installer.xpc/Contents/MacOS/Installer"
    : > "$b/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
    ln -s B "$FRAMEWORK/Versions/Current"
    ln -s Versions/Current/Sparkle "$FRAMEWORK/Sparkle"
    ln -s Versions/Current/Autoupdate "$FRAMEWORK/Autoupdate"
    ln -s Versions/Current/Updater.app "$FRAMEWORK/Updater.app"
    ln -s Versions/Current/Resources "$FRAMEWORK/Resources"
    ln -s Versions/Current/XPCServices "$FRAMEWORK/XPCServices"
}

# prepare [NAME=value ...]: runs the script with the variables Xcode sets for a
# signed Debug build; the arguments override them.
prepare() {
    run env -u ACTION \
        TARGET_BUILD_DIR="$BUILD" FRAMEWORKS_FOLDER_PATH="$FRAMEWORKS_FOLDER_PATH" \
        DERIVED_FILE_DIR="$T/Derived" CODE_SIGNING_ALLOWED=YES \
        EXPANDED_CODE_SIGN_IDENTITY="RoomForMac Self-Signed" ENABLE_HARDENED_RUNTIME=NO \
        CODESIGN="$T/codesign" "$@" "$ROOT/scripts/prepare-sparkle.sh"
}

# tab_line ARG...: the line the stub logs for a call with these arguments.
tab_line() {
    local IFS=$'\t'
    printf '%s\n' "$*"
}

signings() {
    wc -l < "$STATE/codesign.log" | tr -d ' '
}

@test "it deletes the XPC services and signs Autoupdate, Updater.app and the framework, in that order" {
    local sign=(--force --sign "RoomForMac Self-Signed" --timestamp=none --preserve-metadata=identifier)
    local expected
    prepare
    [ "$status" -eq 0 ]
    [ ! -e "$FRAMEWORK/Versions/B/XPCServices" ]
    [ ! -L "$FRAMEWORK/XPCServices" ]
    [ -f "$FRAMEWORK/Versions/B/Autoupdate" ]
    [ -d "$FRAMEWORK/Versions/B/Updater.app" ]
    expected="$(
        tab_line "${sign[@]}" "$FRAMEWORK/Versions/B/Autoupdate"
        tab_line "${sign[@]}" "$FRAMEWORK/Versions/B/Updater.app"
        tab_line "${sign[@]}" "$FRAMEWORK"
    )"
    [ "$(cat "$STATE/codesign.log")" = "$expected" ]
    [ "$(grep -c -e '--deep' "$STATE/codesign.log" || true)" = 0 ]
    [ "${lines[0]}" = "Signed Autoupdate" ]
    [ "${lines[2]}" = "Signed Sparkle.framework" ]
    [ "${lines[3]}" = "Prepared Sparkle" ]
}

@test "hardened runtime follows the app's setting, between the timestamp and the identifier flags" {
    local sign=(--force --sign "RoomForMac Self-Signed" --timestamp=none --options runtime --preserve-metadata=identifier)
    local expected
    prepare ENABLE_HARDENED_RUNTIME=YES
    [ "$status" -eq 0 ]
    expected="$(
        tab_line "${sign[@]}" "$FRAMEWORK/Versions/B/Autoupdate"
        tab_line "${sign[@]}" "$FRAMEWORK/Versions/B/Updater.app"
        tab_line "${sign[@]}" "$FRAMEWORK"
    )"
    [ "$(cat "$STATE/codesign.log")" = "$expected" ]
}

@test "an ad-hoc build signs with the identity -" {
    local sign=(--force --sign - --timestamp=none --preserve-metadata=identifier)
    prepare EXPANDED_CODE_SIGN_IDENTITY=-
    [ "$status" -eq 0 ]
    [ "$(signings)" = 3 ]
    [ "$(head -n 1 "$STATE/codesign.log")" = "$(tab_line "${sign[@]}" "$FRAMEWORK/Versions/B/Autoupdate")" ]
}

@test "with signing off it still deletes the XPC services and signs nothing" {
    prepare CODE_SIGNING_ALLOWED=NO EXPANDED_CODE_SIGN_IDENTITY=
    [ "$status" -eq 0 ]
    [ ! -e "$FRAMEWORK/Versions/B/XPCServices" ]
    [ ! -L "$FRAMEWORK/XPCServices" ]
    [ ! -s "$STATE/codesign.log" ]
    [ "${lines[0]}" = "Prepared Sparkle" ]
}

@test "a framework without Autoupdate is refused before anything changes" {
    rm "$FRAMEWORK/Versions/B/Autoupdate"
    prepare
    [ "$status" -eq 1 ]
    [[ "$output" == *"error: unexpected Sparkle.framework layout"* ]] || return 1
    [ -d "$FRAMEWORK/Versions/B/XPCServices" ]
    [ ! -s "$STATE/codesign.log" ]
}

@test "a framework without Updater.app is refused before anything changes" {
    rm -rf "$FRAMEWORK/Versions/B/Updater.app"
    prepare
    [ "$status" -eq 1 ]
    [[ "$output" == *"error: unexpected Sparkle.framework layout"* ]] || return 1
    [ -d "$FRAMEWORK/Versions/B/XPCServices" ]
    [ ! -s "$STATE/codesign.log" ]
}

@test "a missing framework is refused, as when the phase runs before Xcode embeds Sparkle" {
    rm -rf "$FRAMEWORK"
    prepare
    [ "$status" -eq 1 ]
    [[ "$output" == *"error: unexpected Sparkle.framework layout"* ]] || return 1
    [ ! -s "$STATE/codesign.log" ]
    [ ! -e "$T/Derived/prepare-sparkle.stamp" ]
}

@test "a second run with nothing changed signs nothing and touches nothing" {
    local before
    prepare
    [ "$status" -eq 0 ]
    before="$(stat -f %Fm "$FRAMEWORK/Versions/B/Autoupdate")"
    prepare
    [ "$status" -eq 0 ]
    [ "$output" = "Sparkle already prepared" ]
    [ "$(signings)" = 3 ]
    [ "$(stat -f %Fm "$FRAMEWORK/Versions/B/Autoupdate")" = "$before" ]
}

@test "it prepares again when the identity, the runtime flag or the framework changed" {
    prepare
    [ "$status" -eq 0 ]
    [ "$(signings)" = 3 ]
    prepare EXPANDED_CODE_SIGN_IDENTITY="Another Identity"
    [ "$status" -eq 0 ]
    [ "$(signings)" = 6 ]
    prepare EXPANDED_CODE_SIGN_IDENTITY="Another Identity" ENABLE_HARDENED_RUNTIME=YES
    [ "$status" -eq 0 ]
    [ "$(signings)" = 9 ]
    # Xcode copied Sparkle.framework again: its XPC services are back.
    mkdir -p "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc"
    ln -s Versions/Current/XPCServices "$FRAMEWORK/XPCServices"
    prepare EXPANDED_CODE_SIGN_IDENTITY="Another Identity" ENABLE_HARDENED_RUNTIME=YES
    [ "$status" -eq 0 ]
    [ "$(signings)" = 12 ]
    [ ! -e "$FRAMEWORK/Versions/B/XPCServices" ]
    [ ! -L "$FRAMEWORK/XPCServices" ]
}

@test "it touches exactly one file, inside the framework, after signing, so Xcode signs the app again" {
    touch -t 200101010000 "$T/reference"
    find "$FRAMEWORK" -exec touch -h -t 200001010000 {} +
    prepare
    [ "$status" -eq 0 ]
    run find "$FRAMEWORK" -type f -newer "$T/reference"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    [[ "$output" == "$FRAMEWORK/Versions/B/"* ]]
}

@test "project.yml declares the file the script touches as the phase's output" {
    local declared
    declared="$(env TARGET_BUILD_DIR="$BUILD" FRAMEWORKS_FOLDER_PATH="$FRAMEWORKS_FOLDER_PATH" ruby -ryaml -e '
        phases = YAML.load_file(ARGV[0]).fetch("targets").fetch("RoomForMac").fetch("postBuildScripts")
        phase = phases.find { |p| p["name"] == "Prepare Sparkle" }
        abort "project.yml has no Prepare Sparkle phase" unless phase
        declared = phase.fetch("outputFiles").fetch(0)
        declared = declared.gsub("$(TARGET_BUILD_DIR)", ENV.fetch("TARGET_BUILD_DIR"))
        puts declared.gsub("$(FRAMEWORKS_FOLDER_PATH)", ENV.fetch("FRAMEWORKS_FOLDER_PATH"))
    ' "$ROOT/project.yml")"
    [[ "$declared" == "$FRAMEWORK/Versions/B/"* ]] || return 1
    [ -f "$declared" ]
    touch -t 200001010000 "$declared"
    touch -t 200101010000 "$T/reference"
    prepare
    [ "$status" -eq 0 ]
    [ "$declared" -nt "$T/reference" ]
}

@test "an Xcode index build changes nothing" {
    rm -rf "$FRAMEWORK"
    prepare ACTION=indexbuild
    [ "$status" -eq 0 ]
    [ "$output" = "Index build: not preparing Sparkle" ]
    [ ! -s "$STATE/codesign.log" ]
}

# --- scripts/lib/sparkle.sh -------------------------------------------------

# fake_artifact DIR VERSION [TOOLS...]: what Swift Package Manager leaves in
# .../artifacts/sparkle/Sparkle: DIR/bin with the named tools (default: all
# three) and a DIR/Sparkle.xcframework whose framework reports VERSION.
fake_artifact() {
    local dir="$1" version="$2" tool resources
    shift 2
    if [[ $# -eq 0 ]]; then
        set -- generate_appcast sign_update generate_keys
    fi
    mkdir -p "$dir/bin"
    for tool in "$@"; do
        printf '#!/bin/bash\nexit 0\n' > "$dir/bin/$tool"
        chmod +x "$dir/bin/$tool"
    done
    resources="$dir/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework/Versions/B/Resources"
    mkdir -p "$resources"
    cat > "$resources/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleShortVersionString</key>
    <string>$version</string>
</dict>
</plist>
PLIST
}

# artifact_in_root and artifact_in_home: where sparkle_bin looks (see the library).
artifact_in_root() {
    printf '%s\n' "$T/checkout/build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle"
}

artifact_in_home() {
    printf '%s\n' "$T/home/Library/Developer/Xcode/DerivedData/RoomForMac-$1/SourcePackages/artifacts/sparkle/Sparkle"
}

# sparkle_bin_run [NAME=value ...]: sparkle_bin for the fake checkout, with HOME
# in the test folder and no SPARKLE_BIN unless given.
sparkle_bin_run() {
    run env -u SPARKLE_BIN HOME="$T/home" "$@" \
        /bin/bash -c 'source "$1/scripts/lib/sparkle.sh" && sparkle_bin "$2"' _ "$ROOT" "$T/checkout"
}

@test "sparkle_bin: the pinned version is 2.10.0" {
    run /bin/bash -c 'source "$1/scripts/lib/sparkle.sh" && echo "$SPARKLE_VERSION"' _ "$ROOT"
    [ "$status" -eq 0 ]
    [ "$output" = "2.10.0" ]
}

@test "sparkle.sh: sourcing it sets no shell option and defines only SPARKLE_VERSION besides functions" {
    run /bin/bash -c '
        (set +o; shopt -p) > "$2/options-before"
        compgen -v | LC_ALL=C sort > "$2/names-before"
        source "$1/scripts/lib/sparkle.sh"
        (set +o; shopt -p) > "$2/options-after"
        compgen -v | LC_ALL=C sort > "$2/names-after"
        cmp "$2/options-before" "$2/options-after" || echo "the library changed a shell option"
        LC_ALL=C comm -13 "$2/names-before" "$2/names-after"' _ "$ROOT" "$T"
    [ "$status" -eq 0 ]
    [ "$output" = "SPARKLE_VERSION" ]
}

@test "sparkle_bin: an explicit SPARKLE_BIN is used as given" {
    mkdir -p "$T/stubs"
    sparkle_bin_run SPARKLE_BIN="$T/stubs"
    [ "$status" -eq 0 ]
    [ "$output" = "$T/stubs" ]
}

@test "sparkle_bin: an explicit SPARKLE_BIN that is not a folder is an error" {
    sparkle_bin_run SPARKLE_BIN="$T/nowhere"
    [ "$status" -eq 1 ]
    [[ "$output" == "error: SPARKLE_BIN=$T/nowhere is not a folder" ]]
}

@test "sparkle_bin: the checkout's build/DerivedData wins over the home folder" {
    fake_artifact "$(artifact_in_root)" 2.10.0
    fake_artifact "$(artifact_in_home plan6)" 2.10.0
    sparkle_bin_run
    [ "$status" -eq 0 ]
    [ "$output" = "$(artifact_in_root)/bin" ]
}

@test "sparkle_bin: the newest valid RoomForMac-* DerivedData in the home folder is used" {
    fake_artifact "$(artifact_in_home old)" 2.10.0
    fake_artifact "$(artifact_in_home plan6)" 2.10.0
    fake_artifact "$(artifact_in_home wrong)" 2.9.6
    touch -t 202601010000 "$(artifact_in_home old)/bin"
    touch -t 202606010000 "$(artifact_in_home plan6)/bin"
    sparkle_bin_run
    [ "$status" -eq 0 ]
    [ "$output" = "$(artifact_in_home plan6)/bin" ]
}

@test "sparkle_bin: a newer download of another Sparkle version is skipped" {
    fake_artifact "$(artifact_in_home old)" 2.10.0
    fake_artifact "$(artifact_in_home wrong)" 2.9.6
    touch -t 202601010000 "$(artifact_in_home old)/bin"
    touch -t 202606010000 "$(artifact_in_home wrong)/bin"
    sparkle_bin_run
    [ "$status" -eq 0 ]
    [ "$output" = "$(artifact_in_home old)/bin" ]
}

@test "sparkle_bin: only another Sparkle version is an error that says what to do" {
    fake_artifact "$(artifact_in_root)" 2.9.6
    sparkle_bin_run
    [ "$status" -eq 1 ]
    [[ "$output" == *"build the app once so Swift Package Manager fetches Sparkle"* ]]
}

@test "sparkle_bin: a download without sign_update is an error" {
    fake_artifact "$(artifact_in_root)" 2.10.0 generate_appcast generate_keys
    sparkle_bin_run
    [ "$status" -eq 1 ]
    [[ "$output" == *"build the app once so Swift Package Manager fetches Sparkle"* ]]
}

@test "sparkle_bin: with nothing built it is an error, and the real home is never read" {
    sparkle_bin_run
    [ "$status" -eq 1 ]
    [ "$output" = "error: Sparkle 2.10.0's tools were not found; build the app once so Swift Package Manager fetches Sparkle" ]
}
