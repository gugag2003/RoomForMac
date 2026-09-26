#!/usr/bin/env bats
# Engine build checks. Builds once per file into a temporary output directory.

setup_file() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    ENGINE_OUT="$BATS_FILE_TMPDIR/engine"
    export ROOT ENGINE_OUT
    if ! "$ROOT/scripts/build-engine.sh" > "$BATS_FILE_TMPDIR/build.log" 2>&1; then
        cat "$BATS_FILE_TMPDIR/build.log" >&2
        return 1
    fi
}

@test "engine contains the scripts, libraries and Go binaries RoomForMac runs" {
    [ -x "$ENGINE_OUT/mole" ]
    [ -x "$ENGINE_OUT/bin/clean.sh" ]
    [ -x "$ENGINE_OUT/bin/uninstall.sh" ]
    [ -f "$ENGINE_OUT/lib/core/common.sh" ]
    [ -x "$ENGINE_OUT/bin/analyze-go" ]
    [ -x "$ENGINE_OUT/bin/status-go" ]
}

@test "Go binaries are universal" {
    run lipo -archs "$ENGINE_OUT/bin/analyze-go"
    [[ "$output" == *arm64* && "$output" == *x86_64* ]] || return 1
    run lipo -archs "$ENGINE_OUT/bin/status-go"
    [[ "$output" == *arm64* && "$output" == *x86_64* ]]
}

@test "the host sudo shim always fails" {
    run "$ENGINE_OUT/host-bin/sudo" -n true
    [ "$status" -eq 1 ]
}

@test "VERSION records the pinned Mole release and patch set" {
    run cat "$ENGINE_OUT/VERSION"
    [[ "$output" == *"mole_tag=V1.56.0"* ]] || return 1
    [[ "$output" == *"mole_commit=239c90d"* ]] || return 1
    [[ "$output" == *"patch_count="* ]]
}

@test "the status binary prints a JSON snapshot" {
    run "$ENGINE_OUT/bin/status-go" --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"cpu"'* ]]
}

@test "patched engine ships the host integration helpers" {
    [ -f "$ENGINE_OUT/lib/core/host.sh" ]
    grep -q '^mole_selection_allows()' "$ENGINE_OUT/lib/core/host.sh"
    grep -q '^mole_auth_disabled()' "$ENGINE_OUT/lib/core/sudo.sh"
}
