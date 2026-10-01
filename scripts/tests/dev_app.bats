#!/usr/bin/env bats
# Checks scripts/dev-app.sh without Xcode, XcodeGen or LaunchServices. HOME is a
# throwaway folder, and stubs stand in for xcodebuild (it makes a minimal app
# bundle where the real one would put the build), xcodegen, lsregister and
# open. The stubs log their arguments to $STATE, so the tests can check what
# ran, and what a run left behind in the fake home folder.

bats_require_minimum_version 1.5.0

setup_file() {
    STUBS="$BATS_FILE_TMPDIR/stubs"
    mkdir -p "$STUBS"

    cat > "$STUBS/xcodebuild" << 'STUB'
#!/bin/bash
# Writes a bundle with an Info.plist where a Debug build of the app goes, unless
# STUB_BUILD_FAIL=1. The bundle's Resources/build file tells the builds apart.
set -euo pipefail
printf '%s\n' "$*" >> "$STATE/xcodebuild.log"
[[ "${STUB_BUILD_FAIL:-0}" != 1 ]] || {
    echo "** BUILD FAILED **" >&2
    exit 65
}
derived=""
while (($# > 0)); do
    [[ "$1" == -derivedDataPath ]] && derived="$2"
    shift
done
app="$derived/Build/Products/Debug/RoomForMac.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
plutil -create xml1 "$app/Contents/Info.plist"
plutil -insert CFBundleIdentifier -string com.roomformac.RoomForMac "$app/Contents/Info.plist"
printf '%s\n' "${STUB_BUILD_LABEL:-new}" > "$app/Contents/Resources/build"
STUB
    printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$STATE/xcodegen.log"\n' > "$STUBS/xcodegen"
    printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$STATE/lsregister.log"\n' > "$STUBS/lsregister"
    printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$STATE/open.log"\n' > "$STUBS/open"
    chmod +x "$STUBS"/*
}

setup() {
    export STATE="$BATS_TEST_TMPDIR/state"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$STATE" "$HOME"
    export XCODEBUILD="$BATS_FILE_TMPDIR/stubs/xcodebuild"
    export XCODEGEN="$BATS_FILE_TMPDIR/stubs/xcodegen"
    export LSREGISTER="$BATS_FILE_TMPDIR/stubs/lsregister"
    export OPEN="$BATS_FILE_TMPDIR/stubs/open"
    unset RFM_DEV_DERIVED_DATA RFM_DEV_APP XCODE_DERIVED_DATA STUB_BUILD_FAIL STUB_BUILD_LABEL
    SCRIPT="$BATS_TEST_DIRNAME/../dev-app.sh"
    DD="$HOME/Library/Developer/Xcode/DerivedData"
    INSTALLED="$HOME/Applications/RoomForMac Dev.app"
}

# make_bundle APP BUNDLE_ID: a minimal app bundle.
make_bundle() {
    mkdir -p "$1/Contents/MacOS"
    plutil -create xml1 "$1/Contents/Info.plist"
    plutil -insert CFBundleIdentifier -string "$2" "$1/Contents/Info.plist"
}

@test "builds Debug into the hidden DerivedData folder and installs the one copy" {
    run "$SCRIPT"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    grep -q -- "-scheme RoomForMac -configuration Debug" "$STATE/xcodebuild.log"
    grep -q -- "-derivedDataPath $DD/RoomForMac-dev.noindex " "$STATE/xcodebuild.log"
    grep -q -- "--use-cache" "$STATE/xcodegen.log"
    [ "$(cat "$INSTALLED/Contents/Resources/build")" = new ]
    [ "$(cat "$STATE/lsregister.log")" = "-f $INSTALLED" ]
    [[ "$output" == *"Installed $INSTALLED"* ]]
    # Nothing is left of the staging copy, and nothing is opened unasked.
    [ "$(find "$HOME/Applications" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" -eq 1 ]
    [ ! -e "$STATE/open.log" ]
}

@test "refuses a build folder that Spotlight would index" {
    RFM_DEV_DERIVED_DATA="$DD/RoomForMac-dev" run "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"must end in .noindex"* ]]
    [ ! -e "$STATE/xcodebuild.log" ]
}

@test "a failed build leaves the installed copy as it was" {
    STUB_BUILD_LABEL=old run "$SCRIPT"
    [ "$status" -eq 0 ]

    STUB_BUILD_FAIL=1 run "$SCRIPT"
    [ "$status" -ne 0 ]
    [ "$(cat "$INSTALLED/Contents/Resources/build")" = old ]
}

@test "replaces the previous copy" {
    STUB_BUILD_LABEL=old run "$SCRIPT"
    [ "$status" -eq 0 ]
    STUB_BUILD_LABEL=new run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(cat "$INSTALLED/Contents/Resources/build")" = new ]
}

@test "never replaces an app that is not RoomForMac" {
    make_bundle "$INSTALLED" com.example.Other
    run "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"is not RoomForMac"* ]]
    [ "$(plutil -extract CFBundleIdentifier raw "$INSTALLED/Contents/Info.plist")" = com.example.Other ]
}

@test "removes the other RoomForMac builds in DerivedData and keeps everything else" {
    make_bundle "$DD/RoomForMac-abc/Build/Products/Debug/RoomForMac.app" com.roomformac.RoomForMac
    make_bundle "$DD/RoomForMac-abc/Build/Products/Debug/RoomForMacUITests-Runner.app" com.roomformac.RoomForMacUITests.xctrunner
    make_bundle "$DD/RoomForMac-plan6/Build/Products/Release/RoomForMac.app" com.roomformac.RoomForMac
    make_bundle "$DD/RoomForMac-old.noindex/Build/Products/Debug/RoomForMac.app" com.roomformac.RoomForMac
    make_bundle "$DD/Other-xyz/Build/Products/Debug/RoomForMacStyle.app" com.example.Style

    run "$SCRIPT"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    [ ! -e "$DD/RoomForMac-abc/Build/Products/Debug/RoomForMac.app" ]
    [ ! -e "$DD/RoomForMac-abc/Build/Products/Debug/RoomForMacUITests-Runner.app" ]
    [ ! -e "$DD/RoomForMac-plan6/Build/Products/Release/RoomForMac.app" ]
    [[ "$output" == *"Removed $DD/RoomForMac-plan6/Build/Products/Release/RoomForMac.app"* ]]
    # Hidden folders, the script's own build and other apps stay.
    [ -e "$DD/RoomForMac-old.noindex/Build/Products/Debug/RoomForMac.app" ]
    [ -e "$DD/RoomForMac-dev.noindex/Build/Products/Debug/RoomForMac.app" ]
    [ -e "$DD/Other-xyz/Build/Products/Debug/RoomForMacStyle.app" ]
}

@test "--keep-others keeps the other builds" {
    make_bundle "$DD/RoomForMac-abc/Build/Products/Debug/RoomForMac.app" com.roomformac.RoomForMac
    run "$SCRIPT" --keep-others
    [ "$status" -eq 0 ]
    [ -e "$DD/RoomForMac-abc/Build/Products/Debug/RoomForMac.app" ]
}

@test "quits a running copy before replacing it, and keeps a running build in DerivedData" {
    STUB_BUILD_LABEL=old run "$SCRIPT"
    [ "$status" -eq 0 ]
    other="$DD/RoomForMac-abc/Build/Products/Debug/RoomForMac.app"
    make_bundle "$other" com.roomformac.RoomForMac
    # sleep stands in for each app, named after its executable, so ps shows the bundle path.
    (exec -a "$INSTALLED/Contents/MacOS/RoomForMac" /bin/sleep 60) &
    installed_pid=$!
    (exec -a "$other/Contents/MacOS/RoomForMac" /bin/sleep 60) &
    other_pid=$!

    run "$SCRIPT"
    kill "$other_pid" 2> /dev/null || true
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    # Gone, or a zombie that only waits for this shell to reap it.
    state="$(ps -p "$installed_pid" -o stat= || true)"
    [[ -z "$state" || "$state" == Z* ]]
    [[ "$output" == *"Quitting the running copy"* ]]
    [ "$(cat "$INSTALLED/Contents/Resources/build")" = new ]
    [ -e "$other" ]
    [[ "$output" == *"Kept $other: it is running"* ]]
}

@test "--open launches the copy with the arguments after --" {
    run "$SCRIPT" --open -- -RFMUITestScenario onboarded
    [ "$status" -eq 0 ]
    [ "$(cat "$STATE/open.log")" = "$INSTALLED --args -RFMUITestScenario onboarded" ]
}

@test "launch arguments without --open are refused" {
    run "$SCRIPT" -- -RFMUITestScenario onboarded
    [ "$status" -ne 0 ]
    [[ "$output" == *"need --open"* ]]
    [ ! -e "$STATE/xcodebuild.log" ]
}
