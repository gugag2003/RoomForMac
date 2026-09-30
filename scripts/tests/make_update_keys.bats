#!/usr/bin/env bats
# Checks scripts/make-update-keys.sh without the real keychain, without Sparkle
# and without a real key. Each test runs a copy of the script inside a throwaway
# git repository, with HOME and TMPDIR in the test folder and a stub executable on
# the GENERATE_KEYS variable. The stub keeps its "keychain" in $STATE and logs
# every call to $STATE/generate_keys.log, so the tests can check exactly what
# would have run. The keys and seeds below are fixed test strings, not secrets.

setup_file() {
    STUBS="$BATS_FILE_TMPDIR/stubs"
    mkdir -p "$STUBS/bin"

    cat > "$STUBS/generate_keys" << 'STUB'
#!/bin/bash
# generate_keys(1) stand-in. Its keychain is $STATE/keychain: one file per
# account, the public key on the first line and the seed on the second. Only the
# options the script may use are accepted, and --account is required: the real
# tool's default account is the one every other Sparkle app on the Mac uses.
set -euo pipefail
printf '%s\n' "$*" >> "$STATE/generate_keys.log"
account=""
mode=create
target=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --account)
            account="$2"
            shift 2
            ;;
        -p)
            mode=print
            shift
            ;;
        -x)
            mode=export
            target="$2"
            shift 2
            ;;
        *)
            echo "stub generate_keys: unexpected argument: $1" >&2
            exit 64
            ;;
    esac
done
if [[ -z "$account" ]]; then
    echo "stub generate_keys: --account is required" >&2
    exit 64
fi
item="$STATE/keychain/$account"
case "$mode" in
    print)
        # $STUB_PRINT replaces the answer. $STUB_NOKEY_STATUS is the exit status
        # of "no key" (the real tool's status is not known, so both are tried).
        if [[ -n "${STUB_PRINT:-}" ]]; then
            printf '%s\n' "$STUB_PRINT"
        elif [[ -f "$item" ]]; then
            head -n 1 "$item"
        else
            echo "no key"
            exit "${STUB_NOKEY_STATUS:-1}"
        fi
        ;;
    create)
        if [[ "${STUB_CREATE_FAIL:-0}" == 1 ]]; then
            echo "generate_keys: the keychain refused access" >&2
            exit 1
        fi
        mkdir -p "$STATE/keychain"
        if [[ ! -f "$item" ]]; then
            printf '%s\n%s\n' "$STUB_NEW_KEY" "$STUB_NEW_SEED" > "$item"
        fi
        printf '<key>SUPublicEDKey</key>\n<string>%s</string>\n' "$(head -n 1 "$item")"
        ;;
    export)
        if [[ "${STUB_EXPORT_FAIL:-0}" == 1 ]]; then
            echo "generate_keys: keychain access denied" >&2
            exit 1
        fi
        if [[ ! -f "$item" ]]; then
            echo "generate_keys: no key to export" >&2
            exit 1
        fi
        # $STUB_EXPORT_CONTENT replaces the file's text, and an empty value
        # writes an empty file.
        if [[ -n "${STUB_EXPORT_CONTENT+x}" ]]; then
            printf '%b' "$STUB_EXPORT_CONTENT" > "$target"
        else
            sed -n 2p "$item" > "$target"
        fi
        # The worst case: the tool leaves the file readable by everyone.
        chmod 644 "$target"
        if [[ "${STUB_LEAK:-0}" == 1 ]]; then
            sed -n 2p "$item"
            sed -n 2p "$item" >&2
        fi
        ;;
esac
STUB

    # The script prints `gh secret set …` but must never run it.
    cat > "$STUBS/bin/gh" << 'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$STATE/gh.log"
exit 1
STUB

    chmod +x "$STUBS/generate_keys" "$STUBS/bin/gh"
    export STUBS
}

setup() {
    TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
    REPO="$TMP/repo"
    STATE="$TMP/state"
    HOME="$TMP/home"
    TMPDIR="$TMP/tmp"
    UPDATES_DIR="$TMP/updates"
    XCCONFIG="$REPO/Config/Distribution.xcconfig"
    mkdir -p "$REPO/scripts/lib" "$REPO/Config" "$STATE" "$HOME" "$TMPDIR"
    cp "$BATS_TEST_DIRNAME/../make-update-keys.sh" "$REPO/scripts/"
    cp "$BATS_TEST_DIRNAME/../lib/distribution.sh" "$REPO/scripts/lib/"
    git -c init.defaultBranch=main init --quiet "$REPO"
    SCRIPT="$REPO/scripts/make-update-keys.sh"
    PATH="$STUBS/bin:$PATH"
    # 32 bytes in base64: 43 characters and "=".
    KEY_A=cm9vbWZvcm1hYy10ZXN0LUtFWS1BLTAxMjM0NTY3ODk=
    KEY_B=cm9vbWZvcm1hYy10ZXN0LUtFWS1CLTAxMjM0NTY3ODk=
    SEED_A=cm9vbWZvcm1hYy10ZXN0LVNFRUQtQS0wMTIzNDU2Nzg=
    SEED_B=cm9vbWZvcm1hYy10ZXN0LVNFRUQtQi0wMTIzNDU2Nzg=
    # What `generate_keys` creates when a test lets it.
    STUB_NEW_KEY="$KEY_A"
    STUB_NEW_SEED="$SEED_A"
    GENERATE_KEYS="$STUBS/generate_keys"
    export HOME TMPDIR STATE PATH GENERATE_KEYS STUB_NEW_KEY STUB_NEW_SEED
    write_xcconfig "" > "$XCCONFIG"
}

# The file Task 1 ships, shortened: the key line sits between other lines, and a
# commented copy of it comes first. write_xcconfig KEY prints it with KEY on the
# key line ("" leaves the value empty).
write_xcconfig() {
    cat << 'EOF'
// Distribution identifiers. Public values.
RFM_REPOSITORY = gugag2003/RoomForMac
RFM_FEED_URL = https:/$()/github.com/gugag2003/RoomForMac/releases/latest/download/appcast.xml
// RFM_SPARKLE_PUBLIC_KEY = not this line
EOF
    if [[ -n "$1" ]]; then
        printf 'RFM_SPARKLE_PUBLIC_KEY = %s\n' "$1"
    else
        printf 'RFM_SPARKLE_PUBLIC_KEY =\n'
    fi
    printf 'RFM_DMG_VOLUME_NAME = RoomForMac\n'
}

# add_key ACCOUNT KEY SEED: puts a key in the stub's keychain.
add_key() {
    mkdir -p "$STATE/keychain"
    printf '%s\n%s\n' "$2" "$3" > "$STATE/keychain/$1"
}

# The calls the stub logged, with the throwaway export folder made unique per run
# replaced by <export>.
calls() {
    sed "s#-x $UPDATES_DIR/\\.export\\.[A-Za-z0-9]*/#-x <export>/#" "$STATE/generate_keys.log"
}

@test "--help prints the usage and exits 0 without touching the keychain" {
    run "$SCRIPT" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: scripts/make-update-keys.sh [--account NAME] [--dir DIR] [--check] [--help]"* ]] || return 1
    [ ! -e "$STATE/generate_keys.log" ]
}

@test "an unknown flag is a usage error" {
    run "$SCRIPT" --force
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: unknown argument: --force"* ]] || return 1
    [ ! -e "$STATE/generate_keys.log" ]
}

@test "a missing or malformed value is a usage error" {
    run "$SCRIPT" --account
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: --account needs a value"* ]] || return 1
    run "$SCRIPT" --account -x
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: --account needs a value"* ]] || return 1
    run "$SCRIPT" --dir --check
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: --dir needs a value"* ]] || return 1
    run "$SCRIPT" --account 'not valid'
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: --account may contain only"* ]] || return 1
    run env LC_ALL=en_US.UTF-8 "$SCRIPT" --account "$(printf 'caf\303\251')"
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: --account may contain only"* ]] || return 1
    [ ! -e "$STATE/generate_keys.log" ]
}

@test "--dir inside the repository is refused before anything is created" {
    run "$SCRIPT" --dir "$REPO/updates"
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: --dir must be outside the repository"* ]] || return 1
    ln -s "$REPO/Config" "$TMP/config-link"
    run "$SCRIPT" --dir "$TMP/config-link/updates"
    [ "$status" -eq 2 ]
    run "$SCRIPT" --dir "$TMP/REPO/updates"
    [ "$status" -eq 2 ]
    run "$SCRIPT" --dir "$TMP/missing/../repo/updates"
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: --dir must not contain '..'"* ]] || return 1
    cd "$REPO/Config"
    run "$SCRIPT" --dir ../new/updates
    [ "$status" -eq 2 ]
    run "$SCRIPT" --check --dir "$REPO/updates"
    [ "$status" -eq 2 ]
    [ ! -e "$REPO/updates" ]
    [ ! -e "$REPO/Config/updates" ]
    [ ! -e "$REPO/new" ]
    [ ! -e "$STATE/generate_keys.log" ]
}

@test "a fresh run creates the key, fills in the xcconfig and exports the seed" {
    run "$SCRIPT" --dir "$UPDATES_DIR"
    [ "$status" -eq 0 ]
    diff <(calls) - << 'EOF'
--account roomformac -p
--account roomformac
--account roomformac -p
--account roomformac -x <export>/ed25519.key
EOF
    write_xcconfig "$KEY_A" > "$TMP/expected.xcconfig"
    cmp "$XCCONFIG" "$TMP/expected.xcconfig"
    [ "$(cat "$UPDATES_DIR/ed25519.key")" = "$SEED_A" ]
    [ "$(stat -f %Lp "$UPDATES_DIR")" = 700 ]
    [ "$(stat -f %Lp "$UPDATES_DIR/ed25519.key")" = 600 ]
    [ "$(ls -A "$UPDATES_DIR")" = ed25519.key ]
    [[ "$output" == *"Public key:  $KEY_A"* ]] || return 1
    [[ "$output" == *"gh secret set SPARKLE_ED_PRIVATE_KEY --env release < \"$UPDATES_DIR/ed25519.key\""* ]] || return 1
    [[ "$output" == *"Back up $UPDATES_DIR in your password manager"* ]] || return 1
    [ ! -e "$STATE/gh.log" ]
    [ -z "$(ls -A "$TMPDIR")" ]
}

@test "a key with slashes is written so that xcconfig does not read them as a comment" {
    # "/" is a base64 digit, and xcconfig starts a comment at "//".
    local key='ab//cdef///ghijklmnopqrstuvwxyz0123456789+A='
    run env STUB_NEW_KEY="$key" "$SCRIPT" --dir "$UPDATES_DIR"
    [ "$status" -eq 0 ]
    grep -qxF 'RFM_SPARKLE_PUBLIC_KEY = ab/$()/cdef/$()/$()/ghijklmnopqrstuvwxyz0123456789+A=' "$XCCONFIG"
    run grep -c '^RFM_SPARKLE_PUBLIC_KEY.*//' "$XCCONFIG"
    [ "$output" = 0 ]
    # distribution_value gives the key back, so the second run recognises it.
    run "$SCRIPT" --dir "$UPDATES_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"RFM_SPARKLE_PUBLIC_KEY already holds this key"* ]]
}

@test "the default folder is ~/.roomformac/updates, private all the way down" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(stat -f %Lp "$HOME/.roomformac")" = 700 ]
    [ "$(stat -f %Lp "$HOME/.roomformac/updates")" = 700 ]
    [ "$(stat -f %Lp "$HOME/.roomformac/updates/ed25519.key")" = 600 ]
    [ "$(cat "$HOME/.roomformac/updates/ed25519.key")" = "$SEED_A" ]
}

@test "the seed never reaches the output or an argument, even if the tool prints it" {
    run env STUB_LEAK=1 "$SCRIPT" --dir "$UPDATES_DIR"
    [ "$status" -eq 0 ]
    [ "$(cat "$UPDATES_DIR/ed25519.key")" = "$SEED_A" ]
    [[ "$output" != *"$SEED_A"* ]] || return 1
    [[ "$(cat "$STATE/generate_keys.log")" != *"$SEED_A"* ]]
}

@test "a second run changes nothing" {
    run "$SCRIPT" --dir "$UPDATES_DIR"
    [ "$status" -eq 0 ]
    cp "$XCCONFIG" "$TMP/after-first.xcconfig"
    # A write to the xcconfig would fail, and the modes are repaired without one.
    chmod 444 "$XCCONFIG"
    chmod 755 "$UPDATES_DIR"
    chmod 644 "$UPDATES_DIR/ed25519.key"
    : > "$STATE/generate_keys.log"
    run "$SCRIPT" --dir "$UPDATES_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"RFM_SPARKLE_PUBLIC_KEY already holds this key"* ]] || return 1
    [[ "$output" == *"ed25519.key already holds this seed"* ]] || return 1
    diff <(calls) - << 'EOF'
--account roomformac -p
--account roomformac -x <export>/ed25519.key
EOF
    cmp "$XCCONFIG" "$TMP/after-first.xcconfig"
    [ "$(stat -f %Lp "$XCCONFIG")" = 444 ]
    [ "$(cat "$UPDATES_DIR/ed25519.key")" = "$SEED_A" ]
    [ "$(stat -f %Lp "$UPDATES_DIR")" = 700 ]
    [ "$(stat -f %Lp "$UPDATES_DIR/ed25519.key")" = 600 ]
    [ "$(ls -A "$UPDATES_DIR")" = ed25519.key ]
}

@test "an xcconfig that already holds the keychain's key is left alone, and the seed is still exported" {
    add_key roomformac "$KEY_A" "$SEED_A"
    write_xcconfig "$KEY_A" > "$XCCONFIG"
    cp "$XCCONFIG" "$TMP/before.xcconfig"
    chmod 444 "$XCCONFIG"
    run "$SCRIPT" --dir "$UPDATES_DIR"
    [ "$status" -eq 0 ]
    cmp "$XCCONFIG" "$TMP/before.xcconfig"
    [ "$(cat "$UPDATES_DIR/ed25519.key")" = "$SEED_A" ]
    run grep -c -x -e '--account roomformac' "$STATE/generate_keys.log"
    [ "$output" = 0 ]
}

@test "a different key in the xcconfig is refused, and nothing changes" {
    add_key roomformac "$KEY_B" "$SEED_B"
    write_xcconfig "$KEY_A" > "$XCCONFIG"
    cp "$XCCONFIG" "$TMP/before.xcconfig"
    run "$SCRIPT" --dir "$UPDATES_DIR"
    [ "$status" -eq 2 ]
    [[ "$output" == *"sets RFM_SPARKLE_PUBLIC_KEY to $KEY_A, but the keychain account \"roomformac\" holds $KEY_B"* ]] || return 1
    [[ "$output" == *"docs/releasing.md"* && "$output" == *"Rotating the update key"* ]] || return 1
    cmp "$XCCONFIG" "$TMP/before.xcconfig"
    [ ! -e "$UPDATES_DIR" ]
    [ "$(cat "$STATE/generate_keys.log")" = "--account roomformac -p" ]
}

@test "a key in the xcconfig with none in the keychain is refused before one is created" {
    write_xcconfig "$KEY_A" > "$XCCONFIG"
    cp "$XCCONFIG" "$TMP/before.xcconfig"
    run "$SCRIPT" --dir "$UPDATES_DIR"
    [ "$status" -eq 2 ]
    [[ "$output" == *"the keychain account \"roomformac\" holds no key; nothing was changed"* ]] || return 1
    [[ "$output" == *"Rotating the update key"* ]] || return 1
    cmp "$XCCONFIG" "$TMP/before.xcconfig"
    [ ! -e "$STATE/keychain" ]
    [ ! -e "$UPDATES_DIR" ]
    [ "$(cat "$STATE/generate_keys.log")" = "--account roomformac -p" ]
}

@test "both kinds of 'no key' answer from -p lead to creating one" {
    # The real tool's status for "no key" is not known: the stub's first run
    # fails with it (the fresh-run test), and this one exits 0 with text.
    run env STUB_NOKEY_STATUS=0 "$SCRIPT" --dir "$UPDATES_DIR"
    [ "$status" -eq 0 ]
    write_xcconfig "$KEY_A" > "$TMP/expected.xcconfig"
    cmp "$XCCONFIG" "$TMP/expected.xcconfig"
    [ "$(sed -n 2p "$STATE/generate_keys.log")" = "--account roomformac" ]
}

@test "text around the public key in the -p answer is ignored" {
    add_key roomformac "$KEY_A" "$SEED_A"
    run env STUB_PRINT="Public key: $KEY_A (ed25519)" "$SCRIPT" --dir "$UPDATES_DIR"
    [ "$status" -eq 0 ]
    write_xcconfig "$KEY_A" > "$TMP/expected.xcconfig"
    cmp "$XCCONFIG" "$TMP/expected.xcconfig"
}

@test "a public key that is not 44 base64 characters is never written" {
    write_xcconfig "" > "$TMP/before.xcconfig"
    local bad
    for bad in "${KEY_A%=}" "${KEY_A}A" "${KEY_A/=/!}" "${KEY_A:0:20} ${KEY_A:20}" "not a key"; do
        run env STUB_PRINT="$bad" "$SCRIPT" --dir "$UPDATES_DIR"
        [ "$status" -eq 1 ]
        [[ "$output" == *"did not report a public key of 44 base64 characters"* ]] || return 1
        cmp "$XCCONFIG" "$TMP/before.xcconfig"
        [ ! -e "$UPDATES_DIR" ]
    done
    run grep -c -e ' -x ' "$STATE/generate_keys.log"
    [ "$output" = 0 ]
}

@test "a failed creation is reported and nothing is written" {
    run env STUB_CREATE_FAIL=1 "$SCRIPT" --dir "$UPDATES_DIR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"generate_keys: the keychain refused access"* ]] || return 1
    [[ "$output" == *"error: generate_keys could not create the update key"* ]] || return 1
    write_xcconfig "" > "$TMP/before.xcconfig"
    cmp "$XCCONFIG" "$TMP/before.xcconfig"
    [ ! -e "$UPDATES_DIR" ]
}

@test "a seed file with another seed is refused and left as it was" {
    mkdir -p "$UPDATES_DIR"
    chmod 700 "$UPDATES_DIR"
    printf '%s\n' "$SEED_B" > "$UPDATES_DIR/ed25519.key"
    chmod 600 "$UPDATES_DIR/ed25519.key"
    cp "$UPDATES_DIR/ed25519.key" "$TMP/seed-before"
    write_xcconfig "" > "$TMP/before.xcconfig"
    run "$SCRIPT" --dir "$UPDATES_DIR"
    [ "$status" -eq 2 ]
    [[ "$output" == *"$UPDATES_DIR/ed25519.key holds a different seed than the keychain account \"roomformac\"; nothing was changed"* ]] || return 1
    [[ "$output" != *"$SEED_A"* && "$output" != *"$SEED_B"* ]] || return 1
    cmp "$UPDATES_DIR/ed25519.key" "$TMP/seed-before"
    cmp "$XCCONFIG" "$TMP/before.xcconfig"
    [ "$(ls -A "$UPDATES_DIR")" = ed25519.key ]
    [ -z "$(ls -A "$TMPDIR")" ]
}

@test "a failed export leaves no file and no temporary folder, and a rerun succeeds" {
    run env STUB_EXPORT_FAIL=1 "$SCRIPT" --dir "$UPDATES_DIR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"generate_keys: keychain access denied"* ]] || return 1
    [[ "$output" == *"error: generate_keys could not export the seed of the account \"roomformac\""* ]] || return 1
    [ -z "$(ls -A "$UPDATES_DIR")" ]
    write_xcconfig "" > "$TMP/before.xcconfig"
    cmp "$XCCONFIG" "$TMP/before.xcconfig"
    [ -z "$(ls -A "$TMPDIR")" ]
    run "$SCRIPT" --dir "$UPDATES_DIR"
    [ "$status" -eq 0 ]
    [ "$(cat "$UPDATES_DIR/ed25519.key")" = "$SEED_A" ]
}

@test "an exported file that is not one line of base64 is refused" {
    write_xcconfig "" > "$TMP/before.xcconfig"
    local content
    for content in '' 'not base64!\n' 'short=\n' "${SEED_A}\n${SEED_B}\n"; do
        run env STUB_EXPORT_CONTENT="$content" "$SCRIPT" --dir "$UPDATES_DIR"
        [ "$status" -eq 1 ]
        [[ "$output" == *"error: generate_keys wrote "* ]] || return 1
        cmp "$XCCONFIG" "$TMP/before.xcconfig"
        [ -z "$(ls -A "$UPDATES_DIR")" ]
    done
}

@test "a symlink in place of the seed file is refused and not followed" {
    mkdir -p "$UPDATES_DIR"
    ln -s "$TMP/elsewhere" "$UPDATES_DIR/ed25519.key"
    run "$SCRIPT" --dir "$UPDATES_DIR"
    [ "$status" -eq 2 ]
    [[ "$output" == *"ed25519.key is not a regular file; nothing was changed"* ]] || return 1
    [ -L "$UPDATES_DIR/ed25519.key" ]
    [ ! -e "$TMP/elsewhere" ]
}

@test "--check succeeds when the xcconfig holds the keychain's key, and changes nothing" {
    add_key roomformac "$KEY_A" "$SEED_A"
    write_xcconfig "$KEY_A" > "$XCCONFIG"
    cp "$XCCONFIG" "$TMP/before.xcconfig"
    chmod 444 "$XCCONFIG"
    run "$SCRIPT" --check --dir "$UPDATES_DIR"
    [ "$status" -eq 0 ]
    [ "$output" = "$KEY_A matches RFM_SPARKLE_PUBLIC_KEY" ]
    [ "$("$SCRIPT" --check 2> /dev/null)" = "$KEY_A matches RFM_SPARKLE_PUBLIC_KEY" ]
    [ "$(sort -u "$STATE/generate_keys.log")" = "--account roomformac -p" ]
    cmp "$XCCONFIG" "$TMP/before.xcconfig"
    [ ! -e "$UPDATES_DIR" ]
    [ ! -e "$HOME/.roomformac" ]
}

@test "--check exits 1 on a mismatch, on an empty xcconfig and when there is no key" {
    add_key roomformac "$KEY_B" "$SEED_B"
    write_xcconfig "$KEY_A" > "$XCCONFIG"
    run "$SCRIPT" --check
    [ "$status" -eq 1 ]
    [[ "$output" == *"mismatch: the keychain account \"roomformac\" holds $KEY_B, but RFM_SPARKLE_PUBLIC_KEY is $KEY_A"* ]] || return 1
    [ -z "$("$SCRIPT" --check 2> /dev/null)" ]
    write_xcconfig "" > "$XCCONFIG"
    run "$SCRIPT" --check
    [ "$status" -eq 1 ]
    [[ "$output" == *"holds $KEY_B, but RFM_SPARKLE_PUBLIC_KEY is empty"* ]] || return 1
    [ -z "$("$SCRIPT" --check 2> /dev/null)" ]
    rm -r "$STATE/keychain"
    write_xcconfig "$KEY_A" > "$XCCONFIG"
    run "$SCRIPT" --check
    [ "$status" -eq 1 ]
    [ "$output" = 'no update key for account "roomformac" in the keychain' ]
    [ -z "$("$SCRIPT" --check 2> /dev/null)" ]
    [ ! -e "$HOME/.roomformac" ]
    [ ! -e "$STATE/gh.log" ]
    run grep -c -v -x -e '--account roomformac -p' "$STATE/generate_keys.log"
    [ "$output" = 0 ]
}

@test "--account names the keychain account in every call" {
    run "$SCRIPT" --account other.key --dir "$UPDATES_DIR"
    [ "$status" -eq 0 ]
    [ -f "$STATE/keychain/other.key" ]
    [ ! -e "$STATE/keychain/roomformac" ]
    run grep -c -v '^--account other.key' "$STATE/generate_keys.log"
    [ "$output" = 0 ]
}

@test "without GENERATE_KEYS the tool comes from sparkle_bin" {
    mkdir -p "$TMP/sparkle-bin"
    cp "$STUBS/generate_keys" "$TMP/sparkle-bin/generate_keys"
    cat > "$REPO/scripts/lib/sparkle.sh" << EOF
sparkle_bin() { printf '%s\n' "$TMP/sparkle-bin"; }
EOF
    run env -u GENERATE_KEYS "$SCRIPT" --dir "$UPDATES_DIR"
    [ "$status" -eq 0 ]
    [ "$(head -n 1 "$STATE/generate_keys.log")" = "--account roomformac -p" ]
    [ "$(cat "$UPDATES_DIR/ed25519.key")" = "$SEED_A" ]
}

@test "without GENERATE_KEYS, a missing Sparkle stops the run before the keychain" {
    cat > "$REPO/scripts/lib/sparkle.sh" << 'EOF'
sparkle_bin() {
    echo "error: build the app once so Swift Package Manager fetches Sparkle" >&2
    return 1
}
EOF
    run env -u GENERATE_KEYS "$SCRIPT" --dir "$UPDATES_DIR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"build the app once so Swift Package Manager fetches Sparkle"* ]] || return 1
    [ ! -e "$STATE/generate_keys.log" ]
    [ ! -e "$UPDATES_DIR" ]
}

@test "a GENERATE_KEYS that does not exist is reported" {
    run env GENERATE_KEYS="$TMP/missing" "$SCRIPT" --dir "$UPDATES_DIR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"error: generate_keys not found or not executable: $TMP/missing"* ]] || return 1
    [ ! -e "$UPDATES_DIR" ]
}

@test "an xcconfig without exactly one key line stops the run before the keychain" {
    printf 'RFM_REPOSITORY = gugag2003/RoomForMac\n' > "$XCCONFIG"
    run "$SCRIPT" --dir "$UPDATES_DIR"
    [ "$status" -eq 1 ]
    {
        write_xcconfig ""
        printf 'RFM_SPARKLE_PUBLIC_KEY =\n'
    } > "$XCCONFIG"
    run "$SCRIPT" --dir "$UPDATES_DIR"
    [ "$status" -eq 1 ]
    [ ! -e "$STATE/generate_keys.log" ]
    [ ! -e "$UPDATES_DIR" ]
}

@test "--dir may not be HOME, an ancestor of HOME or the repository, or /; nothing is chmodded" {
    chmod 755 "$HOME" "$TMP"
    for d in "$HOME" "$HOME/" "$TMP" "/"; do
        run "$SCRIPT" --dir "$d"
        [ "$status" -eq 2 ]
        [[ "$output" == *"error: --dir must be a folder of its own"* ]] || return 1
    done
    [ "$(stat -f %Lp "$HOME")" = 755 ]
    [ "$(stat -f %Lp "$TMP")" = 755 ]
    [ -z "$(ls -A "$HOME")" ]
    [ ! -e "$STATE/generate_keys.log" ]
}

@test "--dir with a control character or newline is refused before any output" {
    run "$SCRIPT" --dir "$TMP/up
dates"
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: --dir must not contain control characters"* ]] || return 1
    run "$SCRIPT" --dir "$TMP/up"$'\t'"dates"
    [ "$status" -eq 2 ]
    [ ! -e "$STATE/generate_keys.log" ]
    [ ! -e "$TMP/up" ]
}

@test "--dir that is a dangling symlink is refused with a clear message" {
    ln -s "$TMP/nowhere" "$TMP/dangling"
    run "$SCRIPT" --dir "$TMP/dangling"
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: --dir is a symbolic link that points nowhere"* ]] || return 1
    [ ! -e "$STATE/generate_keys.log" ]
}
