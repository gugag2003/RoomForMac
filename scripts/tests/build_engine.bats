#!/usr/bin/env bats
# Engine build checks. Builds once per file into a temporary output directory,
# then checks the two Xcode "Prepare engine" scripts against that engine. The
# engine lock tests run a scratch copy of build-engine.sh (see fake_root).
#
# Tests never raise a real system prompt: `status-go --json` asks Finder for the
# disk's free space, so it runs only with RFM_ALLOW_PROMPTS=1 (CI sets it).

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
    if [[ "${RFM_ALLOW_PROMPTS:-0}" != "1" ]]; then
        skip "set RFM_ALLOW_PROMPTS=1 to run status-go --json, which asks Finder for free space and may prompt"
    fi
    run "$ENGINE_OUT/bin/status-go" --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"cpu"'* ]]
}

@test "patched engine ships the host integration helpers" {
    [ -f "$ENGINE_OUT/lib/core/host.sh" ]
    grep -q '^mole_selection_allows()' "$ENGINE_OUT/lib/core/host.sh"
    grep -q '^mole_auth_disabled()' "$ENGINE_OUT/lib/core/sudo.sh"
}

@test "VERSION records the builder hash" {
    local builder
    # build-engine.sh followed by the inputs library it sources: both shape the build.
    builder="$(cat "$ROOT/scripts/build-engine.sh" "$ROOT/scripts/lib/engine-inputs.sh" | shasum -a 256 | cut -d' ' -f1)"
    run grep -A 1 '^patch_count=' "$ENGINE_OUT/VERSION"
    [ "$status" -eq 0 ]
    [ "${lines[1]}" = "builder_sha256=$builder" ]
}

@test "engine ships Mole's license" {
    cmp "$ROOT/vendor/mole/LICENSE" "$ENGINE_OUT/LICENSE"
}

@test "ensure-engine accepts an engine built from the current inputs" {
    run env RFM_ENGINE_DIR="$ENGINE_OUT" RFM_NO_ENGINE_BUILD=1 "$ROOT/scripts/ensure-engine.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "Engine is up to date: $ENGINE_OUT" ]
}

@test "ensure-engine treats an engine without builder_sha256 as stale" {
    mkdir "$BATS_TEST_TMPDIR/old"
    grep -v '^builder_sha256=' "$ENGINE_OUT/VERSION" > "$BATS_TEST_TMPDIR/old/VERSION"
    run env RFM_ENGINE_DIR="$BATS_TEST_TMPDIR/old" RFM_NO_ENGINE_BUILD=1 "$ROOT/scripts/ensure-engine.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is missing or stale"* ]]
}

@test "ensure-engine treats an engine from another build script as stale" {
    mkdir "$BATS_TEST_TMPDIR/other"
    sed 's/^builder_sha256=.*/builder_sha256=0000/' "$ENGINE_OUT/VERSION" > "$BATS_TEST_TMPDIR/other/VERSION"
    run env RFM_ENGINE_DIR="$BATS_TEST_TMPDIR/other" RFM_NO_ENGINE_BUILD=1 "$ROOT/scripts/ensure-engine.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is missing or stale"* ]]
}

@test "ensure-engine refuses to build a missing engine when builds are off" {
    run env RFM_ENGINE_DIR="$BATS_TEST_TMPDIR/none" RFM_NO_ENGINE_BUILD=1 "$ROOT/scripts/ensure-engine.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is missing or stale"* ]] || return 1
    [ ! -e "$BATS_TEST_TMPDIR/none" ]
}

@test "ensure-engine never builds the engine during an Xcode index build" {
    mkdir "$BATS_TEST_TMPDIR/stale"
    sed 's/^builder_sha256=.*/builder_sha256=0000/' "$ENGINE_OUT/VERSION" > "$BATS_TEST_TMPDIR/stale/VERSION"
    run env RFM_ENGINE_DIR="$BATS_TEST_TMPDIR/stale" ACTION=indexbuild "$ROOT/scripts/ensure-engine.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "Index build: not building the engine" ]
    [ "$(ls -A "$BATS_TEST_TMPDIR/stale")" = "VERSION" ]
    grep -qx 'builder_sha256=0000' "$BATS_TEST_TMPDIR/stale/VERSION"
}

# A scratch checkout holding only build-engine.sh, its library and a vendor/mole
# that git cannot read, so a build stops right after it takes the lock. These
# tests never touch the real build/.engine.lock or build/engine-src.
fake_root() {
    local fake="$BATS_TEST_TMPDIR/root"
    mkdir -p "$fake/scripts/lib" "$fake/vendor/mole" "$fake/build"
    cp "$ROOT/scripts/build-engine.sh" "$fake/scripts/"
    cp "$ROOT/scripts/lib/engine-inputs.sh" "$fake/scripts/lib/"
    printf 'gitdir: %s\n' "$BATS_TEST_TMPDIR/no-such-repo" > "$fake/vendor/mole/.git"
    echo "$fake"
}

@test "a second engine build waits for the lock, then gives up and leaves it" {
    local fake lock start
    fake="$(fake_root)"
    lock="$fake/build/.engine.lock"
    mkdir "$lock"
    start=$SECONDS
    run env RFM_ENGINE_LOCK_TIMEOUT=2 "$fake/scripts/build-engine.sh"
    [ "$status" -eq 1 ]
    [ $((SECONDS - start)) -ge 2 ]
    [ "${lines[0]}" = "Waiting for another engine build to finish ($lock)" ]
    [ "${lines[1]}" = "error: another engine build still holds $lock after 2s; if no engine build is running, remove it: rm -rf $lock" ]
    [ -d "$lock" ]
}

@test "a waiting engine build takes the lock once it is free and removes it on exit" {
    local fake lock
    fake="$(fake_root)"
    lock="$fake/build/.engine.lock"
    mkdir "$lock"
    (sleep 1 && rmdir "$lock") 3>&- &
    run env RFM_ENGINE_LOCK_TIMEOUT=30 "$fake/scripts/build-engine.sh"
    wait
    # Past the lock, the build stops at the unreadable vendor/mole.
    [ "$status" -eq 128 ]
    [ "${lines[0]}" = "Waiting for another engine build to finish ($lock)" ]
    [[ "$output" == *"not a git repository"* ]] || return 1
    [ ! -e "$lock" ]
}

@test "engine-expectation writes the engine's VERSION as Swift" {
    local out="$BATS_TEST_TMPDIR/Generated/EngineExpectation.swift"
    run env RFM_ENGINE_DIR="$ENGINE_OUT" SCRIPT_OUTPUT_FILE_0="$out" "$ROOT/scripts/engine-expectation.sh"
    [ "$status" -eq 0 ]
    value() { sed -n "s/^$1=//p" "$ENGINE_OUT/VERSION"; }
    cat > "$BATS_TEST_TMPDIR/expected.swift" << SWIFT
// Generated by scripts/engine-expectation.sh from build/engine/VERSION. Do not edit.
enum EngineExpectation {
    static let moleTag = "$(value mole_tag)"
    static let moleCommit = "$(value mole_commit)"
    static let patchesSHA256 = "$(value patches_sha256)"
    static let patchCount = $(value patch_count)
}
SWIFT
    diff "$BATS_TEST_TMPDIR/expected.swift" "$out"
    xcrun swiftc -parse-as-library -typecheck "$out"
}

@test "engine-expectation rewrites the Swift file only when VERSION changes" {
    local out="$BATS_TEST_TMPDIR/EngineExpectation.swift" before
    mkdir "$BATS_TEST_TMPDIR/engine"
    cp "$ENGINE_OUT/VERSION" "$BATS_TEST_TMPDIR/engine/VERSION"
    export RFM_ENGINE_DIR="$BATS_TEST_TMPDIR/engine" SCRIPT_OUTPUT_FILE_0="$out"
    "$ROOT/scripts/engine-expectation.sh"
    touch -t 200001010000 "$out"
    before="$(stat -f %m "$out")"
    run "$ROOT/scripts/engine-expectation.sh"
    [ "$output" = "Engine expectation unchanged" ]
    [ "$(stat -f %m "$out")" = "$before" ]
    sed -i '' 's/^patch_count=.*/patch_count=42/' "$RFM_ENGINE_DIR/VERSION"
    run "$ROOT/scripts/engine-expectation.sh"
    [[ "$output" == "Engine expectation updated"* ]] || return 1
    grep -qx '    static let patchCount = 42' "$out"
}

@test "engine-expectation fails clearly when VERSION lacks a key" {
    mkdir "$BATS_TEST_TMPDIR/engine"
    grep -v '^patches_sha256=' "$ENGINE_OUT/VERSION" > "$BATS_TEST_TMPDIR/engine/VERSION"
    run env RFM_ENGINE_DIR="$BATS_TEST_TMPDIR/engine" SCRIPT_OUTPUT_FILE_0="$BATS_TEST_TMPDIR/out.swift" \
        "$ROOT/scripts/engine-expectation.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"has no patches_sha256"* ]] || return 1
    [ ! -e "$BATS_TEST_TMPDIR/out.swift" ]
}

@test "engine-expectation rejects values it would have to escape" {
    local bad
    mkdir "$BATS_TEST_TMPDIR/engine"
    for bad in 'mole_tag=V1"56' 'mole_commit=239c\n90d' 'patch_count=5x'; do
        {
            grep -v "^${bad%%=*}=" "$ENGINE_OUT/VERSION"
            printf '%s\n' "$bad"
        } > "$BATS_TEST_TMPDIR/engine/VERSION"
        run env RFM_ENGINE_DIR="$BATS_TEST_TMPDIR/engine" SCRIPT_OUTPUT_FILE_0="$BATS_TEST_TMPDIR/out.swift" \
            "$ROOT/scripts/engine-expectation.sh"
        [ "$status" -eq 1 ]
        [[ "$output" == *"${bad%%=*}"* ]] || return 1
    done
    [ ! -e "$BATS_TEST_TMPDIR/out.swift" ]
}
