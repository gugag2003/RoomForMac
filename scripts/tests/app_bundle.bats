#!/usr/bin/env bats
# Checks a built RoomForMac.app: the embedded engine, its helpers' signatures
# and the architectures. Run it after a build:
#
#   APP=build/DerivedData/Build/Products/Release/RoomForMac.app EXPECT_UNIVERSAL=1 \
#       bats scripts/tests/app_bundle.bats
#
# Without APP every test is skipped, so `bats scripts/tests` still passes.

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
    export ROOT APP ENGINE HELPERS SOURCE_ENGINE
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
}

@test "Contents/Helpers holds exactly the two Go tools" {
    run ls "$HELPERS"
    [ "$status" -eq 0 ]
    [ "$output" = $'analyze-go\nstatus-go' ]
}

@test "each helper is signed as com.roomformac.app.engine.<tool>" {
    local tool
    for tool in analyze-go status-go; do
        run codesign --display --verbose=2 "$HELPERS/$tool"
        [ "$status" -eq 0 ]
        grep -qx "Identifier=com.roomformac.app.engine.$tool" <<< "$output"
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

@test "the bundled status tool prints a JSON snapshot" {
    run "$ENGINE/bin/status-go" --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"cpu"'* ]]
}
