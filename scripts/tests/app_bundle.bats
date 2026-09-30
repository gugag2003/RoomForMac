#!/usr/bin/env bats
# Checks a built RoomForMac.app: the embedded engine, its helpers' signatures,
# the status stubs and the architectures. Run it after a build:
#
#   APP=build/DerivedData/Build/Products/Release/RoomForMac.app EXPECT_UNIVERSAL=1 \
#       bats scripts/tests/app_bundle.bats
#
# Without APP every test is skipped, so `bats scripts/tests` still passes.
#
# EXPECT_HARDENED=1 (a Release build, which has the hardened runtime on) also checks
# the runtime flag on the app and its nested code, exactly the two entitlements the
# app needs, and that no binary carries get-task-allow.
#
# Tests never raise a real system prompt, so the bundled status tool only runs
# with -h here: `status-go --json` asks Finder for the disk's free space, which
# can show an Automation prompt for the terminal. Set RFM_ALLOW_PROMPTS=1 (CI
# does) to also check its JSON snapshot. The bundled status stubs run from a copy
# whose real tools are spies (status_stub_spy.bash), so a broken stub fails a test
# instead of querying Bluetooth or Finder.

load status_stub_spy

setup_file() {
    if [[ -z "${APP:-}" ]]; then
        skip "set APP=/path/to/RoomForMac.app to check a built app"
    fi
    if [[ ! -d "$APP/Contents" ]]; then
        echo "APP=$APP is not an app bundle" >&2
        return 1
    fi
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    APP="${APP%/}"
    ENGINE="$APP/Contents/Resources/engine"
    HELPERS="$APP/Contents/Helpers"
    SOURCE_ENGINE="${RFM_ENGINE_DIR:-$ROOT/build/engine}"
    SPARKLE_FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
    export ROOT APP ENGINE HELPERS SOURCE_ENGINE SPARKLE_FRAMEWORK
}

# "adhoc" for an ad-hoc signature, otherwise the certificate chain.
signer() {
    local info
    info="$(codesign --display --verbose=2 "$1" 2>&1)" || return 1
    if grep -qx 'Signature=adhoc' <<< "$info"; then
        echo adhoc
    else
        grep '^Authority=' <<< "$info"
    fi
}

# "runtime" when the signature carries the hardened-runtime flag, otherwise "plain".
runtime_state() {
    local info
    info="$(codesign --display --verbose=2 "$1" 2>&1)" || return 1
    if grep -Eq '^CodeDirectory .* flags=0x[0-9a-f]+\([^)]*runtime' <<< "$info"; then
        echo runtime
    else
        echo plain
    fi
}

# The architectures of a Mach-O file, sorted: "arm64 x86_64" for a universal binary.
archs_of() {
    lipo -archs "$1" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//'
}

# A value of Config/Distribution.xcconfig, read the way the scripts read it.
dist_value() {
    (source "$ROOT/scripts/lib/distribution.sh" && distribution_value "$ROOT" "$1")
}

# plist_value FILE KEY: a top-level value of a property list. Fails when KEY is missing.
plist_value() {
    plutil -extract "$2" raw -o - "$1"
}

# The entitlements $1 is signed with, as sorted "key=value" lines ("com.apple.…=true");
# nothing when it has none. Fails when codesign cannot read the signature.
entitlement_pairs() {
    local xml
    xml="$(codesign --display --entitlements - --xml "$1" 2> /dev/null)" || return 1
    [[ -n "$xml" ]] || return 0
    plutil -p - <<< "$xml" | sed -n 's/^ *"\([^"]*\)" => \(.*\)$/\1=\2/p' | LC_ALL=C sort
}

# Skips the calling test unless the build is expected to run with the hardened runtime.
require_hardened() {
    if [[ "${EXPECT_HARDENED:-0}" != "1" ]]; then
        skip "set EXPECT_HARDENED=1 to check the hardened runtime of a Release build"
    fi
}

@test "the app passes strict deep signature verification" {
    run codesign --verify --deep --strict --verbose=2 "$APP"
    [ "$status" -eq 0 ]
}

@test "the app and the engine helpers are universal" {
    if [[ "${EXPECT_UNIVERSAL:-0}" != "1" ]]; then
        skip "set EXPECT_UNIVERSAL=1 to check a Release build"
    fi
    local binary
    for binary in "$APP/Contents/MacOS/RoomForMac" "$HELPERS/analyze-go" "$HELPERS/status-go"; do
        run lipo -archs "$binary"
        [ "$status" -eq 0 ]
        [ "$output" = "x86_64 arm64" ]
    done
    # Sparkle's own binaries, whatever order their fat headers list the slices in.
    local updater
    updater="$(plist_value "$SPARKLE_FRAMEWORK/Versions/B/Updater.app/Contents/Info.plist" CFBundleExecutable)"
    [ -n "$updater" ]
    for binary in "$SPARKLE_FRAMEWORK/Versions/B/Sparkle" "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate" \
        "$SPARKLE_FRAMEWORK/Versions/B/Updater.app/Contents/MacOS/$updater"; do
        [ "$(archs_of "$binary")" = "arm64 x86_64" ]
    done
}

@test "Contents/Helpers holds exactly the two Go tools" {
    run ls "$HELPERS"
    [ "$status" -eq 0 ]
    [ "$output" = $'analyze-go\nstatus-go' ]
}

@test "engine/status-bin holds the two status stubs as executable scripts" {
    local stub
    run ls "$ENGINE/status-bin"
    [ "$status" -eq 0 ]
    [ "$output" = $'osascript\nsystem_profiler' ]
    for stub in osascript system_profiler; do
        [ -f "$ENGINE/status-bin/$stub" ]
        [ ! -L "$ENGINE/status-bin/$stub" ]
        [ -x "$ENGINE/status-bin/$stub" ]
        if lipo -archs "$ENGINE/status-bin/$stub" > /dev/null 2>&1; then
            echo "Mach-O status stub: $ENGINE/status-bin/$stub" >&2
            return 1
        fi
        cmp "$SOURCE_ENGINE/status-bin/$stub" "$ENGINE/status-bin/$stub"
    done
}

@test "the bundled status stubs refuse Finder and Bluetooth" {
    spy_stub "$ENGINE/status-bin/osascript"
    run env PATH="$SPY_PATH" "$SPIED" -e \
        'tell application "Finder" to return {free space of startup disk, capacity of startup disk}'
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [ ! -s "$SPY_LOG" ]
    spy_stub "$ENGINE/status-bin/system_profiler"
    run env PATH="$SPY_PATH" "$SPIED" SPBluetoothDataType
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [ ! -s "$SPY_LOG" ]
}

@test "each helper is signed as com.roomformac.RoomForMac.engine.<tool>" {
    local tool
    for tool in analyze-go status-go; do
        run codesign --display --verbose=2 "$HELPERS/$tool"
        [ "$status" -eq 0 ]
        grep -qx "Identifier=com.roomformac.RoomForMac.engine.$tool" <<< "$output"
    done
}

@test "the helpers are signed by the app's identity" {
    local app_signer tool
    app_signer="$(signer "$APP")"
    [ -n "$app_signer" ]
    for tool in analyze-go status-go; do
        [ "$(signer "$HELPERS/$tool")" = "$app_signer" ]
    done
}

@test "engine/bin links each Go tool into Contents/Helpers" {
    local tool
    for tool in analyze-go status-go; do
        [ -L "$ENGINE/bin/$tool" ]
        [ "$(readlink "$ENGINE/bin/$tool")" = "../../../Helpers/$tool" ]
        [ -x "$ENGINE/bin/$tool" ]
    done
}

@test "no Mach-O code is left in Contents/Resources" {
    local file
    while IFS= read -r -d '' file; do
        if lipo -archs "$file" > /dev/null 2>&1; then
            echo "Mach-O in Resources: $file" >&2
            return 1
        fi
    done < <(find "$APP/Contents/Resources" -type f -print0)
}

@test "the bundled VERSION is the engine this build embedded" {
    cmp "$SOURCE_ENGINE/VERSION" "$ENGINE/VERSION"
}

@test "the bundled engine ships Mole's license" {
    cmp "$ROOT/vendor/mole/LICENSE" "$ENGINE/LICENSE"
}

@test "the bundled status tool starts and prints its usage" {
    run "$ENGINE/bin/status-go" -h
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "Usage: mo status [OPTIONS]" ]
}

@test "the bundled status tool prints a JSON snapshot" {
    if [[ "${RFM_ALLOW_PROMPTS:-0}" != "1" ]]; then
        skip "set RFM_ALLOW_PROMPTS=1 to run status-go --json, which asks Finder for free space and may prompt"
    fi
    run "$ENGINE/bin/status-go" --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"cpu"'* ]]
}

# --- Sparkle (Plan 6, Task 3) -----------------------------------------------
# The Prepare Sparkle phase, the Info.plist keys and the notice. Signer checks
# compare with the app's own: on an ad-hoc build that is "adhoc" for both, so the
# runtime-flag check below is what shows an ad-hoc build re-signed Sparkle.

@test "Sparkle.framework is embedded at the pinned version, without any XPC service" {
    local version
    version="$(source "$ROOT/scripts/lib/sparkle.sh" && echo "$SPARKLE_VERSION")"
    [ -d "$SPARKLE_FRAMEWORK/Versions/B" ]
    [ -f "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate" ]
    [ -d "$SPARKLE_FRAMEWORK/Versions/B/Updater.app" ]
    run plist_value "$SPARKLE_FRAMEWORK/Versions/B/Resources/Info.plist" CFBundleShortVersionString
    [ "$status" -eq 0 ]
    [ "$output" = "$version" ]
    run find "$APP" \( -name XPCServices -o -name '*.xpc' \)
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "Sparkle.framework is the only framework in the app" {
    run bash -c 'cd "$1/Contents/Frameworks" && ls -d *.framework' _ "$APP"
    [ "$status" -eq 0 ]
    [ "$output" = "Sparkle.framework" ]
}

@test "Autoupdate, Updater.app and Sparkle.framework are signed by the app's identity" {
    local app_signer part
    app_signer="$(signer "$APP")"
    [ -n "$app_signer" ]
    for part in "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate" "$SPARKLE_FRAMEWORK/Versions/B/Updater.app" "$SPARKLE_FRAMEWORK"; do
        [ "$(signer "$part")" = "$app_signer" ]
    done
}

@test "Autoupdate, Updater.app and Sparkle.framework have the app's hardened-runtime state" {
    local app_state part
    app_state="$(runtime_state "$APP")"
    [ -n "$app_state" ]
    for part in "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate" "$SPARKLE_FRAMEWORK/Versions/B/Updater.app" "$SPARKLE_FRAMEWORK"; do
        [ "$(runtime_state "$part")" = "$app_state" ]
    done
}

@test "Info.plist has the feed, the public key slot and the site URL" {
    local plist="$APP/Contents/Info.plist" feed
    feed="$(dist_value RFM_FEED_URL)"
    [ "$(plist_value "$plist" CFBundleIdentifier)" = "com.roomformac.RoomForMac" ]
    [ "$(plist_value "$plist" SUFeedURL)" = "$feed" ]
    [[ "$feed" == https://* ]] || return 1
    [ "$(plist_value "$plist" SUPublicEDKey)" = "$(dist_value RFM_SPARKLE_PUBLIC_KEY)" ]
    [ "$(plist_value "$plist" SUEnableAutomaticChecks)" = "true" ]
    [ "$(plist_value "$plist" RFMSiteURL)" = "$(dist_value RFM_SITE_URL)" ]
}

@test "Info.plist sets none of the Sparkle keys we leave at their defaults" {
    local plist="$APP/Contents/Info.plist" key
    [ -n "$(plist_value "$plist" CFBundleIdentifier)" ]
    for key in SUEnableInstallerLauncherService SUEnableDownloaderService SUVerifyUpdateBeforeExtraction \
        SURequireSignedFeed SUEnableSystemProfiling SUAutomaticallyUpdate SUScheduledCheckInterval; do
        if plist_value "$plist" "$key" > /dev/null 2>&1; then
            echo "Info.plist must not set $key" >&2
            return 1
        fi
    done
}

@test "the bundled Sparkle license is the repository's" {
    cmp "$ROOT/ThirdParty/Sparkle/LICENSE" "$APP/Contents/Resources/ThirdParty/Sparkle/LICENSE"
}

# --- Hardened runtime (Plan 6, Task 4) ---------------------------------------
# Only with EXPECT_HARDENED=1, for a Release build: the runtime flag on the app
# and its nested code (Task 3's runtime_state), the app's two entitlements, and
# no get-task-allow or helper entitlement anywhere.

@test "the app, the helpers and Sparkle's nested code carry the hardened runtime flag" {
    require_hardened
    local target
    for target in "$APP" "$HELPERS/analyze-go" "$HELPERS/status-go" \
        "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate" "$SPARKLE_FRAMEWORK/Versions/B/Updater.app" "$SPARKLE_FRAMEWORK"; do
        if [ "$(runtime_state "$target")" != runtime ]; then
            echo "no hardened runtime flag: $target" >&2
            return 1
        fi
    done
}

@test "the app is signed with the two entitlements hardened runtime needs and no others" {
    require_hardened
    run entitlement_pairs "$APP"
    [ "$status" -eq 0 ]
    [ "$output" = $'com.apple.security.automation.apple-events=true\ncom.apple.security.cs.disable-library-validation=true' ]
}

@test "no Mach-O in the bundle carries get-task-allow" {
    require_hardened
    local file pairs seen=0
    while IFS= read -r -d '' file; do
        if ! lipo -archs "$file" > /dev/null 2>&1; then
            continue
        fi
        seen=$((seen + 1))
        if ! pairs="$(entitlement_pairs "$file")"; then
            echo "cannot read the entitlements of $file" >&2
            return 1
        fi
        if grep -q 'com.apple.security.get-task-allow' <<< "$pairs"; then
            echo "get-task-allow: $file" >&2
            return 1
        fi
    done < <(find "$APP/Contents" -type f -print0)
    # The app, both helpers, Sparkle, Autoupdate and Updater: a find that saw fewer proved nothing.
    [ "$seen" -ge 6 ]
}

@test "the helpers, Autoupdate and Updater.app are signed without entitlements" {
    require_hardened
    local target pairs
    for target in "$HELPERS/analyze-go" "$HELPERS/status-go" \
        "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate" "$SPARKLE_FRAMEWORK/Versions/B/Updater.app"; do
        if ! pairs="$(entitlement_pairs "$target")"; then
            echo "cannot read the entitlements of $target" >&2
            return 1
        fi
        if [[ -n "$pairs" ]]; then
            echo "entitlements on $target: $pairs" >&2
            return 1
        fi
    done
}
