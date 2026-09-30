#!/usr/bin/env bats
# Checks scripts/import-signing-identity.sh without a real keychain, key or
# signature. Each test runs a copy of the script in a throwaway folder, with
# HOME and TMPDIR inside the test folder and stub executables on the SECURITY,
# OPENSSL and BASE64 variables. A stub keychain is a text file, so the tests
# can check what a real run would have left behind: the keychain, the user
# search list and the temporary files. The stubs log their arguments and the
# secrets they inherit to $STATE, so the tests can check exactly what ran.

# Each @test runs in its own subshell, and the tests change the exported secrets
# on purpose, so shellcheck's subshell notes do not apply.
# shellcheck disable=SC2030,SC2031
bats_require_minimum_version 1.5.0

setup_file() {
    STUBS="$BATS_FILE_TMPDIR/stubs"
    mkdir -p "$STUBS"

    cat > "$STUBS/security" << 'STUB'
#!/bin/bash
# security(1) stand-in. A keychain is a text file: line 1 is "password=<its
# password>", every further line is an identity, "SHA1|name". It is unlocked
# while "<keychain>.unlocked" exists. The user search list is
# $STATE/searchlist, one path per line. Only the exact command lines the script
# must use are accepted, so `find-identity -v` and `import -A` fail.
set -euo pipefail
printf '%s\n' "$*" >> "$STATE/security.log"
printf 'security %s: %s\n' "$1" "$(env | grep -c '^RFM_SIGNING_P12_' || true)" >> "$STATE/env.log"
fail() {
    echo "security: $1" >&2
    exit "${2:-1}"
}
unexpected() {
    echo "stub security: unexpected arguments: $*" >&2
    exit 64
}
stored_password() { sed -n '1s/^password=//p' "$1"; }
remove_from_list() {
    { grep -vxF -- "$1" "$STATE/searchlist" || true; } | sed '/^$/d' > "$STATE/searchlist.new"
    mv "$STATE/searchlist.new" "$STATE/searchlist"
}
case "$1" in
    create-keychain)
        [[ $# -eq 4 && "$2" == -p ]] || unexpected "$@"
        [[ "${STUB_CREATE_FAIL:-0}" != 1 ]] || fail "SecKeychainCreate: A keychain with the same name already exists." 48
        [[ ! -e "$4" ]] || fail "SecKeychainCreate: A keychain with the same name already exists." 48
        printf 'password=%s\n' "$3" > "$4"
        # Whether the real tool also puts the new keychain on the search list
        # depends on the macOS release, and the script must cope with both.
        if [[ "${STUB_CREATE_NO_LIST:-0}" != 1 ]]; then
            printf '%s\n' "$4" >> "$STATE/searchlist"
        fi
        ;;
    set-keychain-settings)
        [[ $# -eq 4 && "$2" == -lut && "$3" == 21600 ]] || unexpected "$@"
        [[ -f "$4" ]] || fail "SecKeychainCopySettings: The specified keychain could not be found." 44
        ;;
    unlock-keychain)
        [[ $# -eq 4 && "$2" == -p ]] || unexpected "$@"
        [[ -f "$4" ]] || fail "SecKeychainUnlock: The specified keychain could not be found." 44
        [[ "$(stored_password "$4")" == "$3" ]] ||
            fail "SecKeychainUnlock: The user name or passphrase you entered is not correct." 51
        : > "$4.unlocked"
        ;;
    import)
        file="$2"
        shift 2
        keychain="" format="" password="" trusted=""
        while [[ $# -gt 0 ]]; do
            [[ $# -ge 2 ]] || unexpected "$@"
            case "$1" in
                -k) keychain="$2" ;;
                -f) format="$2" ;;
                -P) password="$2" ;;
                -T) trusted="$trusted $2" ;;
                *) unexpected "$@" ;;
            esac
            shift 2
        done
        [[ "$format" == pkcs12 && "$trusted" == " /usr/bin/codesign" ]] || unexpected "import options: $format$trusted"
        [[ -f "$keychain" ]] || fail "SecKeychainItemImport: The specified keychain could not be found." 44
        [[ -e "$keychain.unlocked" ]] || fail "SecKeychainItemImport: User interaction is not allowed." 36
        # What the decoded file and its folder look like while it is in use.
        dirname "$file" > "$STATE/p12-dir"
        printf '%s %s\n' "$(stat -f %Lp "$(dirname "$file")")" "$(stat -f %Lp "$file")" > "$STATE/p12-modes"
        if [[ "$(head -n 1 "$file")" != "FAKE P12 password=$password" ]]; then
            fail "SecKeychainItemImport: MAC verification failed during PKCS12 import (wrong password?)" 1
        fi
        tail -n +2 "$file" >> "$keychain"
        if [[ "${STUB_IMPORT_KILL_PARENT:-0}" == 1 ]]; then
            # A CI cancellation: the script gets TERM while this tool runs.
            [[ "$(ps -o command= -p "$PPID")" == *import-signing-identity.sh* ]] ||
                fail "stub security: refusing to signal $PPID, which is not the script" 64
            kill -TERM "$PPID"
        fi
        echo '1 identity imported.'
        ;;
    set-key-partition-list)
        [[ $# -eq 7 && "$2" == -S && "$3" == apple-tool:,apple: && "$4" == -s && "$5" == -k ]] || unexpected "$@"
        [[ -f "$7" ]] || fail "SecKeychainSetPartitionList: The specified keychain could not be found." 44
        [[ "$(stored_password "$7")" == "$6" ]] ||
            fail "SecKeychainSetPartitionList: The user name or passphrase you entered is not correct." 51
        [[ "${STUB_PARTITION_FAIL:-0}" != 1 ]] || fail "SecItemCopyMatching: The specified item could not be found in the keychain." 44
        echo 'STUB-PARTITION-NOISE keychain: "..."'
        echo 'STUB-PARTITION-NOISE version: 512'
        ;;
    list-keychains)
        [[ $# -ge 3 && "$2" == -d && "$3" == user ]] || unexpected "$@"
        if [[ $# -eq 3 ]]; then
            while IFS= read -r entry; do
                printf '    "%s"\n' "$entry"
            done < "$STATE/searchlist"
        elif [[ "$4" == -s ]]; then
            shift 4
            : > "$STATE/searchlist"
            for entry in "$@"; do
                printf '%s\n' "$entry" >> "$STATE/searchlist"
            done
        else
            unexpected "$@"
        fi
        ;;
    find-identity)
        # Real `find-identity -v` hides untrusted identities, so only the exact
        # form the script must use is accepted.
        [[ $# -eq 4 && "$2" == -p && "$3" == codesigning ]] || unexpected "$@"
        [[ -f "$4" ]] || fail "SecKeychainOpen: The specified keychain could not be found." 44
        echo 'Policy: Code Signing'
        echo '  Matching identities'
        count=0
        while IFS='|' read -r hash name; do
            count=$((count + 1))
            printf '  %d) %s "%s" (CSSMERR_TP_NOT_TRUSTED)\n' "$count" "$hash" "$name"
        done < <(tail -n +2 "$4")
        printf '     %d identities found\n\n' "$count"
        echo '  Valid identities only'
        echo '     0 valid identities found'
        ;;
    delete-keychain)
        [[ $# -eq 2 ]] || unexpected "$@"
        [[ "${STUB_DELETE_FAIL:-0}" != 1 ]] || fail "SecKeychainDelete: The specified keychain could not be deleted." 1
        [[ -f "$2" ]] || fail "SecKeychainDelete: The specified keychain could not be found." 50
        rm -f "$2" "$2.unlocked"
        remove_from_list "$2"
        ;;
    *)
        echo "stub security: unexpected command: $1" >&2
        exit 64
        ;;
esac
STUB

    cat > "$STUBS/openssl" << 'STUB'
#!/bin/bash
# openssl(1) stand-in: only `rand -hex 24`, which returns a fixed password.
set -euo pipefail
printf '%s\n' "$*" >> "$STATE/openssl.log"
printf 'openssl %s: %s\n' "$1" "$(env | grep -c '^RFM_SIGNING_P12_' || true)" >> "$STATE/env.log"
if [[ "$*" != "rand -hex 24" ]]; then
    echo "stub openssl: unexpected arguments: $*" >&2
    exit 64
fi
if [[ "${STUB_OPENSSL_FAIL:-0}" == 1 ]]; then
    echo "openssl: unable to write random bytes" >&2
    exit 1
fi
echo "$STUB_KEYCHAIN_PASSWORD"
STUB

    cat > "$STUBS/base64" << 'STUB'
#!/bin/bash
# base64(1) stand-in: logs its arguments, then decodes stdin with the real tool.
set -euo pipefail
printf '%s\n' "$*" >> "$STATE/base64.log"
printf 'base64 %s: %s\n' "${1:-}" "$(env | grep -c '^RFM_SIGNING_P12_' || true)" >> "$STATE/env.log"
if [[ "$*" != "--decode" ]]; then
    echo "stub base64: unexpected arguments: $*" >&2
    exit 64
fi
if [[ "${STUB_BASE64_FAIL:-0}" == 1 ]]; then
    echo "base64: invalid input" >&2
    exit 1
fi
exec /usr/bin/base64 --decode
STUB

    chmod +x "$STUBS/security" "$STUBS/openssl" "$STUBS/base64"
    export STUBS
}

setup() {
    unset RFM_SIGNING_P12_BASE64 RFM_SIGNING_P12_PASSWORD RFM_SIGNING_IDENTITY_NAME RFM_SIGNING_EXPECTED_SHA1
    unset STUB_CREATE_FAIL STUB_CREATE_NO_LIST STUB_DELETE_FAIL STUB_PARTITION_FAIL STUB_OPENSSL_FAIL STUB_BASE64_FAIL STUB_IMPORT_KILL_PARENT
    TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
    REPO="$TMP/repo"
    STATE="$TMP/state"
    HOME="$TMP/home"
    TMPDIR="$TMP/tmp"
    CI_DIR="$TMP/ci"
    KEYCHAIN="$CI_DIR/rfm-signing.keychain-db"
    LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
    OTHER_KEYCHAIN="$TMP/other keychains/other.keychain-db"
    mkdir -p "$REPO/scripts" "$REPO/Config" "$STATE" "$TMPDIR" "$CI_DIR" "$HOME/Library/Keychains" "$(dirname "$OTHER_KEYCHAIN")"
    : > "$LOGIN_KEYCHAIN"
    : > "$OTHER_KEYCHAIN"
    printf '%s\n%s\n' "$LOGIN_KEYCHAIN" "$OTHER_KEYCHAIN" > "$STATE/searchlist"
    cp "$BATS_TEST_DIRNAME/../import-signing-identity.sh" "$REPO/scripts/"
    SCRIPT="$REPO/scripts/import-signing-identity.sh"
    SECURITY="$STUBS/security"
    OPENSSL="$STUBS/openssl"
    BASE64="$STUBS/base64"
    STUB_KEYCHAIN_PASSWORD=0123456789abcdef0123456789abcdef0123456789abcdef
    P12_PASSWORD=p12-canary-password-7f3a91
    NAME="RoomForMac Self-Signed"
    HASH_A=1A2B3C4D5E6F708192A3B4C5D6E7F8091A2B3C4D
    HASH_B=FFEEDDCCBBAA99887766554433221100FFEEDDCC
    export HOME TMPDIR STATE SECURITY OPENSSL BASE64 STUB_KEYCHAIN_PASSWORD
    use_p12 "$HASH_A" "$NAME"
    export RFM_SIGNING_EXPECTED_SHA1="$HASH_A"
}

# use_p12 SHA1 NAME [SHA1 NAME ...]: the secrets now hold a fake PKCS#12 with
# those identities, protected by $P12_PASSWORD.
use_p12() {
    local file="$TMP/identity.p12"
    printf 'FAKE P12 password=%s\n' "$P12_PASSWORD" > "$file"
    while [[ $# -ge 2 ]]; do
        printf '%s|%s\n' "$1" "$2" >> "$file"
        shift 2
    done
    RFM_SIGNING_P12_BASE64="$(/usr/bin/base64 -i "$file")"
    RFM_SIGNING_P12_PASSWORD="$P12_PASSWORD"
    export RFM_SIGNING_P12_BASE64 RFM_SIGNING_P12_PASSWORD
}

create() {
    run --separate-stderr "$SCRIPT" create "${1:-$KEYCHAIN}"
}

# The user search list as it was before the test: create's failures and delete
# must give it back exactly.
assert_search_list_untouched() {
    [ "$(cat "$STATE/searchlist")" = "$(printf '%s\n%s' "$LOGIN_KEYCHAIN" "$OTHER_KEYCHAIN")" ]
}

# Nothing of a run is left: no keychain, its original search list, no temp file.
assert_cleaned_up() {
    [ ! -e "$KEYCHAIN" ]
    [ ! -e "$KEYCHAIN.unlocked" ]
    assert_search_list_untouched
    [ -z "$(ls -A "$TMPDIR")" ]
}

assert_no_secrets() {
    [[ "$1" != *"$RFM_SIGNING_P12_BASE64"* ]] || return 1
    [[ "$1" != *"$RFM_SIGNING_P12_PASSWORD"* ]] || return 1
    [[ "$1" != *"$STUB_KEYCHAIN_PASSWORD"* ]] || return 1
}

@test "--help prints the usage and exits 0, without running a tool" {
    run "$SCRIPT" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: scripts/import-signing-identity.sh create <keychain-path>"* ]] || return 1
    [[ "$output" == *"RFM_SIGNING_EXPECTED_SHA1"* ]] || return 1
    run "$SCRIPT" create --help
    [ "$status" -eq 0 ]
    [ ! -e "$STATE/security.log" ]
    [ ! -e "$STATE/env.log" ]
}

@test "a missing or unknown action, or the wrong number of paths, is a usage error" {
    run "$SCRIPT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: missing action: create or delete"* ]] || return 1
    run "$SCRIPT" import "$KEYCHAIN"
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: unknown action: import"* ]] || return 1
    run "$SCRIPT" create
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: create needs exactly one argument, the keychain path"* ]] || return 1
    run "$SCRIPT" delete "$KEYCHAIN" extra
    [ "$status" -eq 2 ]
    run "$SCRIPT" create ""
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: the keychain path is empty"* ]] || return 1
    [ ! -e "$STATE/security.log" ]
    [ ! -e "$STATE/env.log" ]
}

@test "create refuses the login keychain and every path inside a keychain folder" {
    local path
    for path in "$LOGIN_KEYCHAIN" \
        "$HOME/Library/Keychains/ci.keychain-db" \
        "$HOME/Library/Keychains/../Keychains/ci.keychain-db" \
        "$HOME/LIBRARY/keychains/ci.keychain-db" \
        /Library/Keychains/ci.keychain-db; do
        run "$SCRIPT" create "$path"
        [ "$status" -eq 2 ]
        [[ "$output" == *" is inside "*": this script handles only a throwaway keychain"* ]] || return 1
    done
    ln -s "$HOME/Library/Keychains" "$TMP/keychains-link"
    run "$SCRIPT" create "$TMP/keychains-link/ci.keychain-db"
    [ "$status" -eq 2 ]
    [ ! -e "$HOME/Library/Keychains/ci.keychain-db" ]
    [ ! -e "$STATE/security.log" ]
    [ ! -e "$STATE/env.log" ]
}

@test "create refuses a path that exists, even a dangling symlink, and changes nothing" {
    printf 'precious\n' > "$KEYCHAIN"
    run "$SCRIPT" create "$KEYCHAIN"
    [ "$status" -eq 2 ]
    [[ "$output" == *"already exists; this script never modifies an existing keychain"* ]] || return 1
    [ "$(cat "$KEYCHAIN")" = precious ]
    rm "$KEYCHAIN"
    ln -s "$TMP/nowhere" "$KEYCHAIN"
    run "$SCRIPT" create "$KEYCHAIN"
    [ "$status" -eq 2 ]
    [ -L "$KEYCHAIN" ]
    [ ! -e "$STATE/security.log" ]
    [ ! -e "$STATE/env.log" ]
}

@test "the keychain path must end in .keychain-db, be free of control characters and lie in a folder that exists" {
    run "$SCRIPT" create "$CI_DIR/ci.keychain"
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: the keychain path must end in .keychain-db"* ]] || return 1
    run "$SCRIPT" delete "$CI_DIR/ci.keychain"
    [ "$status" -eq 2 ]
    run "$SCRIPT" create "$(printf '%s/a\nb.keychain-db' "$CI_DIR")"
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: the keychain path contains a control character"* ]] || return 1
    run "$SCRIPT" create "$TMP/missing/ci.keychain-db"
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: the folder $TMP/missing does not exist"* ]] || return 1
    run "$SCRIPT" create "$TMP/missing/../ci.keychain-db"
    [ "$status" -eq 2 ]
    [[ "$output" == *"must not contain '..' in a part that does not exist yet"* ]] || return 1
    [ ! -e "$STATE/security.log" ]
    [ ! -e "$STATE/env.log" ]
}

@test "create refuses a missing or empty secret, and never names a value" {
    local variable
    for variable in RFM_SIGNING_P12_BASE64 RFM_SIGNING_P12_PASSWORD; do
        run env -u "$variable" "$SCRIPT" create "$KEYCHAIN"
        [ "$status" -eq 2 ]
        [[ "$output" == *"error: $variable is not set; it is a secret of the release environment"* ]] || return 1
        run env "$variable=" "$SCRIPT" create "$KEYCHAIN"
        [ "$status" -eq 2 ]
        [[ "$output" == *"error: $variable is not set"* ]] || return 1
        assert_no_secrets "$output"
    done
    [ ! -e "$STATE/security.log" ]
    [ ! -e "$STATE/env.log" ]
    [ -z "$(ls -A "$TMPDIR")" ]
}

@test "create refuses a malformed identity name or expected SHA-1 before any tool runs" {
    run env 'RFM_SIGNING_IDENTITY_NAME=Bad "Name"' "$SCRIPT" create "$KEYCHAIN"
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: RFM_SIGNING_IDENTITY_NAME may contain only"* ]] || return 1
    run env RFM_SIGNING_IDENTITY_NAME= "$SCRIPT" create "$KEYCHAIN"
    [ "$status" -eq 2 ]
    run env RFM_SIGNING_EXPECTED_SHA1=1A2B "$SCRIPT" create "$KEYCHAIN"
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: RFM_SIGNING_EXPECTED_SHA1 must hold exactly 40 hex digits"* ]] || return 1
    run env "RFM_SIGNING_EXPECTED_SHA1=${HASH_A%?}G" "$SCRIPT" create "$KEYCHAIN"
    [ "$status" -eq 2 ]
    [ ! -e "$STATE/security.log" ]
    [ ! -e "$STATE/openssl.log" ]
    [ ! -e "$STATE/env.log" ]
}

@test "create runs the keychain steps in order, with -T codesign and never -A" {
    create
    [ "$status" -eq 0 ]
    diff <(sed 's#^import .*/identity.p12 #import WORK/identity.p12 #' "$STATE/security.log") - << EOF
create-keychain -p $STUB_KEYCHAIN_PASSWORD $KEYCHAIN
set-keychain-settings -lut 21600 $KEYCHAIN
unlock-keychain -p $STUB_KEYCHAIN_PASSWORD $KEYCHAIN
import WORK/identity.p12 -k $KEYCHAIN -f pkcs12 -P $P12_PASSWORD -T /usr/bin/codesign
set-key-partition-list -S apple-tool:,apple: -s -k $STUB_KEYCHAIN_PASSWORD $KEYCHAIN
list-keychains -d user
list-keychains -d user -s $KEYCHAIN $LOGIN_KEYCHAIN $OTHER_KEYCHAIN
find-identity -p codesigning $KEYCHAIN
EOF
    [ "$(cat "$STATE/openssl.log")" = "rand -hex 24" ]
    [ "$(cat "$STATE/base64.log")" = "--decode" ]
    run grep -c -e ' -A' -e ' -x ' -e ' -v' "$STATE/security.log"
    [ "$output" = 0 ]
}

@test "create puts the keychain first on the search list and keeps the others in order" {
    create
    [ "$status" -eq 0 ]
    diff "$STATE/searchlist" - << EOF
$KEYCHAIN
$LOGIN_KEYCHAIN
$OTHER_KEYCHAIN
EOF
}

@test "create leaves the same search list whether or not create-keychain adds the keychain to it" {
    run env STUB_CREATE_NO_LIST=1 "$SCRIPT" create "$KEYCHAIN"
    [ "$status" -eq 0 ]
    diff "$STATE/searchlist" - << EOF
$KEYCHAIN
$LOGIN_KEYCHAIN
$OTHER_KEYCHAIN
EOF
    run "$SCRIPT" delete "$KEYCHAIN"
    [ "$status" -eq 0 ]
    assert_cleaned_up
}

@test "create prints exactly the two lines for GITHUB_ENV, with an uppercase SHA-1" {
    local lower
    lower="$(printf '%s' "$HASH_A" | tr 'A-F' 'a-f')"
    use_p12 "$lower" "$NAME"
    export RFM_SIGNING_EXPECTED_SHA1="$lower"
    create
    [ "$status" -eq 0 ]
    [ "$output" = "KEYCHAIN=$KEYCHAIN"$'\n'"SIGNING_SHA1=$HASH_A" ]
    [[ "$stderr" == *"the identity \"$NAME\" is ready (SHA-1 $HASH_A)"* ]] || return 1
    [[ "$output$stderr" != *STUB-PARTITION-NOISE* ]] || return 1
    [ -f "$KEYCHAIN" ]
}

@test "create works on a relative path and prints the absolute one" {
    cd "$CI_DIR"
    run --separate-stderr "$SCRIPT" create rfm.keychain-db
    [ "$status" -eq 0 ]
    [ "$output" = "KEYCHAIN=$CI_DIR/rfm.keychain-db"$'\n'"SIGNING_SHA1=$HASH_A" ]
    [ -f "$CI_DIR/rfm.keychain-db" ]
    [ ! -e "$HOME/Library/Keychains/rfm.keychain-db" ]
}

@test "create and delete work on a keychain path that has a space" {
    mkdir "$TMP/ci dir"
    KEYCHAIN="$TMP/ci dir/my signing.keychain-db"
    create
    [ "$status" -eq 0 ]
    [ "$output" = "KEYCHAIN=$KEYCHAIN"$'\n'"SIGNING_SHA1=$HASH_A" ]
    [ "$(head -n 1 "$STATE/searchlist")" = "$KEYCHAIN" ]
    run "$SCRIPT" delete "$KEYCHAIN"
    [ "$status" -eq 0 ]
    assert_cleaned_up
}

@test "create decodes a secret that has line breaks and a trailing newline" {
    RFM_SIGNING_P12_BASE64="$(/usr/bin/base64 -b 40 -i "$TMP/identity.p12")"$'\n'
    export RFM_SIGNING_P12_BASE64
    [ "$(printf '%s' "$RFM_SIGNING_P12_BASE64" | wc -l | tr -d ' ')" -ge 2 ]
    create
    [ "$status" -eq 0 ]
    [ "$output" = "KEYCHAIN=$KEYCHAIN"$'\n'"SIGNING_SHA1=$HASH_A" ]
}

@test "create ignores look-alike names and a repeated listing" {
    use_p12 "$HASH_A" "$NAME" "$HASH_A" "$NAME" "$HASH_B" "$NAME 2" "$HASH_B" "Old $NAME"
    create
    [ "$status" -eq 0 ]
    [ "$output" = "KEYCHAIN=$KEYCHAIN"$'\n'"SIGNING_SHA1=$HASH_A" ]
}

@test "RFM_SIGNING_IDENTITY_NAME selects another identity" {
    use_p12 "$HASH_A" "RoomForMac Spike"
    export RFM_SIGNING_IDENTITY_NAME="RoomForMac Spike"
    create
    [ "$status" -eq 0 ]
    [ "$output" = "KEYCHAIN=$KEYCHAIN"$'\n'"SIGNING_SHA1=$HASH_A" ]
    run "$SCRIPT" delete "$KEYCHAIN"
    [ "$status" -eq 0 ]
    unset RFM_SIGNING_IDENTITY_NAME
    create
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"found 0"* ]] || return 1
    assert_cleaned_up
}

@test "the expected SHA-1 defaults to Config/signing-identity.sha1, whatever its case" {
    unset RFM_SIGNING_EXPECTED_SHA1
    printf '%s\n' "$HASH_B" > "$REPO/Config/signing-identity.sha1"
    create
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"but Config/signing-identity.sha1 says $HASH_B"* ]] || return 1
    assert_cleaned_up
    printf '%s\n' "$HASH_A" | tr 'A-F' 'a-f' > "$REPO/Config/signing-identity.sha1"
    create
    [ "$status" -eq 0 ]
    [ "$output" = "KEYCHAIN=$KEYCHAIN"$'\n'"SIGNING_SHA1=$HASH_A" ]
}

@test "RFM_SIGNING_EXPECTED_SHA1 overrides the pin file" {
    printf '%s\n' "$HASH_B" > "$REPO/Config/signing-identity.sha1"
    create
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"is not checked"* ]] || return 1
}

@test "an empty RFM_SIGNING_EXPECTED_SHA1, or no pin file, skips the check and says so" {
    printf '%s\n' "$HASH_B" > "$REPO/Config/signing-identity.sha1"
    export RFM_SIGNING_EXPECTED_SHA1=
    create
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"warning: the certificate SHA-1 is not checked (RFM_SIGNING_EXPECTED_SHA1 is empty)"* ]] || return 1
    run "$SCRIPT" delete "$KEYCHAIN"
    [ "$status" -eq 0 ]
    unset RFM_SIGNING_EXPECTED_SHA1
    rm "$REPO/Config/signing-identity.sha1"
    create
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"warning: the certificate SHA-1 is not checked (Config/signing-identity.sha1 does not exist)"* ]] || return 1
}

@test "a pin file that is not a SHA-1 is refused, never skipped" {
    unset RFM_SIGNING_EXPECTED_SHA1
    : > "$REPO/Config/signing-identity.sha1"
    create
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"error: Config/signing-identity.sha1 must hold exactly 40 hex digits"* ]] || return 1
    printf 'not a fingerprint\n' > "$REPO/Config/signing-identity.sha1"
    create
    [ "$status" -eq 2 ]
    [ ! -e "$STATE/security.log" ]
    [ ! -e "$STATE/openssl.log" ]
}

@test "the secrets appear nowhere in stdout or stderr when create succeeds" {
    create
    [ "$status" -eq 0 ]
    assert_no_secrets "$output"
    assert_no_secrets "$stderr"
}

@test "the passwords reach argv only where security gives them no other channel" {
    create
    [ "$status" -eq 0 ]
    run bash -c 'grep -F -- "$1" "$2" | cut -d" " -f1 | sort | tr "\n" " "' _ "$STUB_KEYCHAIN_PASSWORD" "$STATE/security.log"
    [ "$output" = "create-keychain set-key-partition-list unlock-keychain " ]
    run bash -c 'grep -F -- "$1" "$2" | cut -d" " -f1 | sort | tr "\n" " "' _ "$P12_PASSWORD" "$STATE/security.log"
    [ "$output" = "import " ]
    run grep -F -- "$P12_PASSWORD" "$STATE/openssl.log" "$STATE/base64.log"
    [ "$status" -eq 1 ]
    run grep -rlF -- "$RFM_SIGNING_P12_BASE64" "$STATE"
    [ "$status" -eq 1 ]
}

@test "no tool inherits a secret through its environment" {
    create
    [ "$status" -eq 0 ]
    run grep -c ': 0$' "$STATE/env.log"
    [ "$output" -ge 10 ]
    run grep -vc ': 0$' "$STATE/env.log"
    [ "$output" = 0 ]
}

@test "the PKCS#12 is decoded into a private folder under TMPDIR, which is gone afterwards" {
    create
    [ "$status" -eq 0 ]
    [ "$(cat "$STATE/p12-modes")" = "700 600" ]
    [ "$(dirname "$(cat "$STATE/p12-dir")")" = "$TMPDIR" ]
    [ -z "$(ls -A "$TMPDIR")" ]
}

@test "two identities of that name fail, and the keychain is deleted again" {
    use_p12 "$HASH_A" "$NAME" "$HASH_B" "$NAME"
    create
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ "$stderr" == *"error: expected one identity named \"$NAME\" in the keychain, found 2"* ]] || return 1
    assert_no_secrets "$stderr"
    grep -qx "delete-keychain $KEYCHAIN" "$STATE/security.log"
    assert_cleaned_up
}

@test "no identity of that name fails, and the keychain is deleted again" {
    use_p12 "$HASH_A" "$NAME 2"
    create
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ "$stderr" == *"error: expected one identity named \"$NAME\" in the keychain, found 0"* ]] || return 1
    grep -qx "delete-keychain $KEYCHAIN" "$STATE/security.log"
    assert_cleaned_up
}

@test "a certificate other than the pinned one fails, and the keychain is deleted again" {
    export RFM_SIGNING_EXPECTED_SHA1="$HASH_B"
    create
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ "$stderr" == *"error: the identity \"$NAME\" has SHA-1 $HASH_A, but RFM_SIGNING_EXPECTED_SHA1 says $HASH_B"* ]] || return 1
    grep -qx "delete-keychain $KEYCHAIN" "$STATE/security.log"
    assert_cleaned_up
}

@test "a wrong PKCS#12 password fails in the import, and the keychain is deleted again" {
    export RFM_SIGNING_P12_PASSWORD=wrong-password-canary
    create
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ "$stderr" == *"error: security import failed (does RFM_SIGNING_P12_PASSWORD belong to RFM_SIGNING_P12_BASE64?)"* ]] || return 1
    [[ "$stderr" != *wrong-password-canary* ]] || return 1
    [[ "$stderr" != *"$P12_PASSWORD"* ]] || return 1
    assert_no_secrets "$stderr"
    assert_cleaned_up
}

@test "a failed set-key-partition-list deletes the keychain" {
    run env STUB_PARTITION_FAIL=1 "$SCRIPT" create "$KEYCHAIN"
    [ "$status" -eq 1 ]
    [[ "$output" == *"error: security set-key-partition-list failed"* ]] || return 1
    assert_cleaned_up
}

@test "a create-keychain that fails deletes nothing and leaves the search list alone" {
    run env STUB_CREATE_FAIL=1 "$SCRIPT" create "$KEYCHAIN"
    [ "$status" -eq 1 ]
    [[ "$output" == *"error: security create-keychain failed"* ]] || return 1
    run grep -c -e '^delete-keychain' -e '^list-keychains' "$STATE/security.log"
    [ "$output" = 0 ]
    assert_cleaned_up
}

@test "a failure before the keychain exists runs no security command" {
    run env STUB_OPENSSL_FAIL=1 "$SCRIPT" create "$KEYCHAIN"
    [ "$status" -eq 1 ]
    [[ "$output" == *"error: openssl could not make a keychain password"* ]] || return 1
    run env STUB_BASE64_FAIL=1 "$SCRIPT" create "$KEYCHAIN"
    [ "$status" -eq 1 ]
    [[ "$output" == *"error: RFM_SIGNING_P12_BASE64 could not be decoded"* ]] || return 1
    run env "RFM_SIGNING_P12_BASE64= " "$SCRIPT" create "$KEYCHAIN"
    [ "$status" -eq 1 ]
    [[ "$output" == *"error: RFM_SIGNING_P12_BASE64 decoded to nothing"* ]] || return 1
    [ ! -e "$STATE/security.log" ]
    assert_cleaned_up
}

@test "a signal during the import deletes the half-made keychain and exits 1" {
    run env STUB_IMPORT_KILL_PARENT=1 "$SCRIPT" create "$KEYCHAIN"
    [ "$status" -eq 1 ]
    grep -qx "delete-keychain $KEYCHAIN" "$STATE/security.log"
    assert_cleaned_up
}

@test "delete takes the keychain off the search list, then deletes it, and keeps the other entries" {
    create
    [ "$status" -eq 0 ]
    : > "$STATE/security.log"
    run "$SCRIPT" delete "$KEYCHAIN"
    [ "$status" -eq 0 ]
    diff "$STATE/security.log" - << EOF
list-keychains -d user
list-keychains -d user -s $LOGIN_KEYCHAIN $OTHER_KEYCHAIN
delete-keychain $KEYCHAIN
EOF
    assert_cleaned_up
}

@test "delete succeeds again when the keychain is gone, and needs none of the secrets" {
    create
    [ "$status" -eq 0 ]
    run env -u RFM_SIGNING_P12_BASE64 -u RFM_SIGNING_P12_PASSWORD -u RFM_SIGNING_EXPECTED_SHA1 "$SCRIPT" delete "$KEYCHAIN"
    [ "$status" -eq 0 ]
    assert_cleaned_up
    : > "$STATE/security.log"
    run "$SCRIPT" delete "$KEYCHAIN"
    [ "$status" -eq 0 ]
    [[ "$output" == *"the keychain $KEYCHAIN is already gone"* ]] || return 1
    [ "$(cat "$STATE/security.log")" = "list-keychains -d user" ]
    run "$SCRIPT" delete "$CI_DIR/never-made.keychain-db"
    [ "$status" -eq 0 ]
    run "$SCRIPT" delete "$TMP/missing-folder/never-made.keychain-db"
    [ "$status" -eq 0 ]
    assert_search_list_untouched
}

@test "delete refuses the login keychain, and every path inside ~/Library/Keychains" {
    run "$SCRIPT" delete "$LOGIN_KEYCHAIN"
    [ "$status" -eq 2 ]
    [[ "$output" == *" is inside "*": this script handles only a throwaway keychain"* ]] || return 1
    [ -f "$LOGIN_KEYCHAIN" ]
    run "$SCRIPT" delete "$HOME/Library/Keychains/other.keychain-db"
    [ "$status" -eq 2 ]
    [ ! -e "$STATE/security.log" ]
    assert_search_list_untouched
}

@test "delete exits 1 when an existing keychain cannot be deleted" {
    create
    [ "$status" -eq 0 ]
    run env STUB_DELETE_FAIL=1 "$SCRIPT" delete "$KEYCHAIN"
    [ "$status" -eq 1 ]
    [[ "$output" == *"error: could not delete $KEYCHAIN"* ]] || return 1
    [ -f "$KEYCHAIN" ]
}

@test "the script never turns shell tracing on" {
    run bash -c 'grep -v "^[[:space:]]*#" "$1" | grep -nE "set (-[A-Za-z]*x|-o xtrace)|xtrace|BASH_XTRACEFD"' _ "$BATS_TEST_DIRNAME/../import-signing-identity.sh"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}
