#!/usr/bin/env bats
# Checks scripts/make-signing-identity.sh without a real keychain, certificate
# or signature. Each test runs a copy of the script inside a throwaway git
# repository, with HOME in the test folder and stub executables on the
# OPENSSL, SECURITY and CODESIGN variables. The stubs log their arguments to
# $STATE, so the tests can check exactly what would have run.

setup_file() {
    STUBS="$BATS_FILE_TMPDIR/stubs"
    mkdir -p "$STUBS/bin"

    cat > "$STUBS/security" << 'STUB'
#!/bin/bash
# security(1) stand-in. Identities are "SHA1|name" lines in $STATE/identities.
set -euo pipefail
printf '%s\n' "$*" >> "$STATE/security.log"
case "$1" in
    find-identity)
        # Real `find-identity -v` hides untrusted identities, so only the
        # exact form the script must use is accepted.
        if [[ "$*" != "find-identity -p codesigning" ]]; then
            echo "stub security: unexpected arguments: $*" >&2
            exit 64
        fi
        echo 'Policy: Code Signing'
        echo '  Matching identities'
        count=0
        if [[ -f "$STATE/identities" ]]; then
            while IFS='|' read -r hash name; do
                count=$((count + 1))
                printf '  %d) %s "%s" (CSSMERR_TP_NOT_TRUSTED)\n' "$count" "$hash" "$name"
            done < "$STATE/identities"
        fi
        printf '     %d identities found\n\n' "$count"
        echo '  Valid identities only'
        echo '     0 valid identities found'
        ;;
    list-keychains)
        printf '    "%s"\n' "$STUB_KEYCHAIN" /Library/Keychains/System.keychain
        ;;
    import)
        file="$2"
        password=""
        shift 2
        while [[ $# -gt 0 ]]; do
            if [[ "$1" == -P ]]; then
                password="$2"
                shift
            fi
            shift
        done
        if [[ "$(head -n 1 "$file")" != "FAKE P12 password=$password" ]]; then
            echo "security: SecKeychainItemImport: MAC verification failed during PKCS12 import (wrong password?)" >&2
            exit 1
        fi
        tail -n +2 "$file" > "$STATE/imported-cert.pem"
        hash="$(shasum -a 1 < "$STATE/imported-cert.pem" | cut -c 1-40 | tr 'a-f' 'A-F')"
        name="$(sed -n 's/^FAKE CERT CN=//p' "$STATE/imported-cert.pem")"
        printf '%s|%s\n' "$hash" "$name" >> "$STATE/identities"
        echo '1 identity imported.'
        ;;
    *)
        echo "stub security: unexpected command: $1" >&2
        exit 64
        ;;
esac
STUB

    cat > "$STUBS/codesign" << 'STUB'
#!/bin/bash
# codesign(1) stand-in: remembers the identity it signed with and prints the
# DR a certificate signature gets, or $STUB_DR when that is set.
set -euo pipefail
printf '%s\n' "$*" >> "$STATE/codesign.log"
for file; do :; done
case "$1" in
    --force)
        if [[ "${STUB_CODESIGN_FAIL:-0}" == 1 ]]; then
            echo "$file: errSecInternalComponent" >&2
            exit 1
        fi
        previous=""
        for argument; do
            if [[ "$previous" == --sign ]]; then
                printf '%s\n' "$argument" > "$STATE/signed-with"
            fi
            previous="$argument"
        done
        echo "$file: replacing existing signature" >&2
        ;;
    --verify)
        [[ -f "$STATE/signed-with" ]]
        ;;
    -d)
        echo "Executable=$file" >&2
        if [[ -n "${STUB_DR:-}" ]]; then
            printf 'designated => %s\n' "$STUB_DR"
        else
            printf 'designated => identifier "com.roomformac.signing-probe" and certificate leaf = H"%s"\n' \
                "$(tr 'A-F' 'a-f' < "$STATE/signed-with")"
        fi
        ;;
    *)
        echo "stub codesign: unexpected arguments: $*" >&2
        exit 64
        ;;
esac
STUB

    cat > "$STUBS/openssl" << 'STUB'
#!/bin/bash
# openssl(1) stand-in: logs its arguments and writes fake files. A fake
# certificate's SHA-1 fingerprint is the SHA-1 of the file. $STUB_CN, when set,
# replaces the CN a new certificate gets, as when LibreSSL re-encodes or trims it.
set -euo pipefail
printf '%s\n' "$*" >> "$STATE/openssl.log"
value_of() {
    local flag="$1"
    shift
    while [[ $# -gt 1 ]]; do
        if [[ "$1" == "$flag" ]]; then
            printf '%s\n' "$2"
            return 0
        fi
        shift
    done
    echo "stub openssl: missing $flag" >&2
    return 64
}
random_hex() {
    head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'
}
case "$1" in
    rand)
        random_hex "$3"
        echo
        ;;
    req)
        config="$(value_of -config "$@")"
        printf 'FAKE KEY %s\n' "$(random_hex 8)" > "$(value_of -keyout "$@")"
        {
            printf 'FAKE CERT CN=%s\n' "${STUB_CN:-$(sed -n 's/^CN = //p' "$config")}"
            printf 'serial=%s\n' "$(value_of -set_serial "$@")"
        } > "$(value_of -out "$@")"
        ;;
    x509)
        certificate="$(value_of -in "$@")"
        case " $* " in
            *" -fingerprint "*)
                printf 'SHA1 Fingerprint=%s\n' "$(shasum -a 1 < "$certificate" | cut -c 1-40 |
                    tr 'a-f' 'A-F' | sed 's/../&:/g; s/:$//')"
                ;;
            *" -subject "*)
                printf 'subject= CN=%s\n' "$(sed -n 's/^FAKE CERT CN=//p' "$certificate")"
                ;;
        esac
        ;;
    pkcs12)
        passout="$(value_of -passout "$@")"
        variable="${passout#env:}"
        {
            printf 'FAKE P12 password=%s\n' "${!variable}"
            cat "$(value_of -in "$@")"
        } > "$(value_of -out "$@")"
        ;;
    *)
        echo "stub openssl: unexpected command: $1" >&2
        exit 64
        ;;
esac
STUB

    # The script prints `gh secret set …` but must never run it.
    cat > "$STUBS/bin/gh" << 'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$STATE/gh.log"
exit 1
STUB

    chmod +x "$STUBS/security" "$STUBS/codesign" "$STUBS/openssl" "$STUBS/bin/gh"
    export STUBS
}

setup() {
    TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
    REPO="$TMP/repo"
    STATE="$TMP/state"
    HOME="$TMP/home"
    SIGNING_DIR="$TMP/signing"
    STUB_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
    mkdir -p "$REPO/scripts" "$REPO/Config" "$STATE" "$HOME/Library/Keychains"
    : > "$STUB_KEYCHAIN"
    cp "$BATS_TEST_DIRNAME/../make-signing-identity.sh" "$REPO/scripts/"
    printf 'Config/Local.xcconfig\n' > "$REPO/.gitignore"
    git -c init.defaultBranch=main init --quiet "$REPO"
    SCRIPT="$REPO/scripts/make-signing-identity.sh"
    PATH="$STUBS/bin:$PATH"
    OPENSSL="$STUBS/openssl"
    SECURITY="$STUBS/security"
    CODESIGN="$STUBS/codesign"
    HASH_A=1A2B3C4D5E6F708192A3B4C5D6E7F8091A2B3C4D
    HASH_B=FFEEDDCCBBAA99887766554433221100FFEEDDCC
    HASH_C=0000000000000000000000000000000000000001
    export HOME STATE STUB_KEYCHAIN PATH OPENSSL SECURITY CODESIGN
}

add_identity() {
    printf '%s|%s\n' "$1" "$2" >> "$STATE/identities"
}

cert_hash() {
    shasum -a 1 < "$SIGNING_DIR/cert.pem" | cut -c 1-40 | tr 'a-f' 'A-F'
}

@test "--help prints the usage and exits 0" {
    run "$SCRIPT" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: scripts/make-signing-identity.sh [--name NAME] [--dir DIR] [--keychain PATH] [--no-import] [--check] [--help]"* ]] || return 1
    [ ! -e "$STATE/security.log" ]
}

@test "an unknown flag is a usage error" {
    run "$SCRIPT" --force
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: unknown argument: --force"* ]] || return 1
    [ ! -e "$STATE/security.log" ]
}

@test "a missing or malformed value is a usage error" {
    run "$SCRIPT" --name
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: --name needs a value"* ]] || return 1
    run "$SCRIPT" --dir --check
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: --dir needs a value"* ]] || return 1
    run "$SCRIPT" --check --name 'Bad "Name"'
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: --name may contain only"* ]] || return 1
    [ ! -e "$STATE/security.log" ]
}

@test "--name refuses non-ASCII letters, even in a UTF-8 locale" {
    # Under en_US.UTF-8, bash 3.2's [:alnum:] and [A-Za-z] accept these, and
    # LibreSSL writes a double-encoded CN that no later --name can match.
    local name
    for name in "$(printf 'Gon\303\247alves Dev')" "$(printf '\303\211cole')" "$(printf 'Stra\303\237e')"; do
        run env LC_ALL=en_US.UTF-8 "$SCRIPT" --name "$name" --dir "$SIGNING_DIR"
        [ "$status" -eq 2 ]
        [[ "$output" == *"error: --name may contain only"* ]] || return 1
    done
    [ ! -e "$SIGNING_DIR" ]
    [ ! -e "$STATE/openssl.log" ]
    [ ! -e "$STATE/security.log" ]
}

@test "--name refuses a leading or trailing space" {
    # LibreSSL trims them, so the certificate would not be CN=NAME.
    local name
    for name in " RoomForMac Dev" "RoomForMac Dev " " RoomForMac Dev "; do
        run env LC_ALL=en_US.UTF-8 "$SCRIPT" --name "$name" --dir "$SIGNING_DIR"
        [ "$status" -eq 2 ]
        [[ "$output" == *"error: --name may contain only"* ]] || return 1
    done
    [ ! -e "$SIGNING_DIR" ]
    [ ! -e "$STATE/openssl.log" ]
    [ ! -e "$STATE/security.log" ]
}

@test "--dir inside the repository is refused before anything is created" {
    run "$SCRIPT" --dir "$REPO/signing"
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: --dir must be outside the repository"* ]] || return 1
    ln -s "$REPO/Config" "$TMP/config-link"
    run "$SCRIPT" --dir "$TMP/config-link/signing"
    [ "$status" -eq 2 ]
    run "$SCRIPT" --dir "$TMP/REPO/signing"
    [ "$status" -eq 2 ]
    run "$SCRIPT" --dir "$TMP/missing/../repo/signing"
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: --dir must not contain '..'"* ]] || return 1
    cd "$REPO/Config"
    run "$SCRIPT" --dir ../new/signing
    [ "$status" -eq 2 ]
    [ ! -e "$REPO/signing" ]
    [ ! -e "$REPO/Config/signing" ]
    [ ! -e "$REPO/new" ]
    [ ! -e "$STATE/security.log" ]
    [ ! -e "$STATE/openssl.log" ]
}

@test "--check with no identity exits 1" {
    run "$SCRIPT" --check
    [ "$status" -eq 1 ]
    [ "$output" = 'no identity named "RoomForMac Self-Signed"' ]
    [ -z "$("$SCRIPT" --check 2> /dev/null)" ]
}

@test "--check with one identity prints its SHA-1 and name" {
    add_identity "$HASH_A" "RoomForMac Self-Signed"
    run "$SCRIPT" --check
    [ "$status" -eq 0 ]
    [ "$output" = "$HASH_A \"RoomForMac Self-Signed\"" ]
    [ "$("$SCRIPT" --check 2> /dev/null)" = "$HASH_A \"RoomForMac Self-Signed\"" ]
    [ "$(sort -u "$STATE/security.log")" = "find-identity -p codesigning" ]
}

@test "--check with two identities of that name is ambiguous" {
    add_identity "$HASH_A" "RoomForMac Self-Signed"
    add_identity "$HASH_B" "RoomForMac Self-Signed"
    run "$SCRIPT" --check
    [ "$status" -eq 2 ]
    [[ "$output" == *"2 identities named \"RoomForMac Self-Signed\""* ]] || return 1
    [[ "$output" == *"$HASH_A"* && "$output" == *"$HASH_B"* ]]
}

@test "--check ignores look-alike names and repeated listings" {
    add_identity "$HASH_A" "RoomForMac Self-Signed"
    add_identity "$HASH_A" "RoomForMac Self-Signed"
    add_identity "$HASH_B" "RoomForMac Self-Signed 2"
    add_identity "$HASH_C" "Old RoomForMac Self-Signed"
    add_identity "$HASH_C" 'Copy of "RoomForMac Self-Signed"'
    run "$SCRIPT" --check
    [ "$status" -eq 0 ]
    [ "$output" = "$HASH_A \"RoomForMac Self-Signed\"" ]
    run "$SCRIPT" --check --name "RoomForMac Self-Signed 2"
    [ "$status" -eq 0 ]
    [ "$output" = "$HASH_B \"RoomForMac Self-Signed 2\"" ]
}

@test "a second identity with the same name is refused and nothing changes" {
    add_identity "$HASH_A" "RoomForMac Self-Signed"
    run "$SCRIPT" --dir "$SIGNING_DIR"
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: the keychain already holds an identity named \"RoomForMac Self-Signed\" ($HASH_A)"* ]] || return 1
    [ ! -e "$SIGNING_DIR" ]
    [ ! -e "$STATE/openssl.log" ]
    [ ! -e "$STATE/codesign.log" ]
    [ ! -e "$REPO/Config/Local.xcconfig" ]
    [ "$(cat "$STATE/security.log")" = "find-identity -p codesigning" ]
}

@test "creates a CN-only, 20-year code-signing certificate in a private folder" {
    run "$SCRIPT" --dir "$SIGNING_DIR"
    [ "$status" -eq 0 ]
    diff "$SIGNING_DIR/openssl.cnf" - << 'EOF'
[ req ]
distinguished_name = dn
x509_extensions    = codesign
prompt             = no
[ dn ]
CN = RoomForMac Self-Signed
[ codesign ]
basicConstraints     = critical, CA:false
keyUsage             = critical, digitalSignature
extendedKeyUsage     = critical, codeSigning
subjectKeyIdentifier = hash
EOF
    grep -qF -- "req -x509 -new -newkey rsa:2048 -nodes -sha256 -days 7300 -set_serial 0x" "$STATE/openssl.log"
    grep -qF -- "-config $SIGNING_DIR/openssl.cnf -keyout $SIGNING_DIR/key.pem -out $SIGNING_DIR/cert.pem" "$STATE/openssl.log"
    [ "$(sed -n 's/.*-set_serial 0x\([0-9a-f]*\) .*/\1/p' "$STATE/openssl.log" | tr -d '\n' | wc -c | tr -d ' ')" = 32 ]
    [ "$(stat -f %Lp "$SIGNING_DIR")" = 700 ]
    local file
    for file in key.pem cert.pem identity.p12 identity.p12.base64 identity.p12.password; do
        [ "$(stat -f %Lp "$SIGNING_DIR/$file")" = 600 ]
    done
}

@test "exports a PKCS#12 that imports on any macOS, plus its base64 copy" {
    run "$SCRIPT" --dir "$SIGNING_DIR"
    [ "$status" -eq 0 ]
    grep -qxF -- "pkcs12 -export -name RoomForMac Self-Signed -inkey $SIGNING_DIR/key.pem -in $SIGNING_DIR/cert.pem -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 -passout env:RFM_P12_PASS -out $SIGNING_DIR/identity.p12" "$STATE/openssl.log"
    grep -qx '[0-9a-f]\{48\}' "$SIGNING_DIR/identity.p12.password"
    [ "$(base64 -D -i "$SIGNING_DIR/identity.p12.base64" | shasum)" = "$(shasum < "$SIGNING_DIR/identity.p12")" ]
}

@test "imports without trust settings and probe-signs with the new identity" {
    run "$SCRIPT" --dir "$SIGNING_DIR"
    [ "$status" -eq 0 ]
    local hash password
    hash="$(cert_hash)"
    password="$(cat "$SIGNING_DIR/identity.p12.password")"
    diff "$STATE/security.log" - << EOF
find-identity -p codesigning
list-keychains -d user
import $SIGNING_DIR/identity.p12 -k $STUB_KEYCHAIN -f pkcs12 -P $password -x -T /usr/bin/codesign
find-identity -p codesigning
EOF
    [ "$(cat "$STATE/identities")" = "$hash|RoomForMac Self-Signed" ]
    grep -qF -- "--force --timestamp=none --identifier com.roomformac.signing-probe --sign $hash " "$STATE/codesign.log"
    grep -qF -- "--verify --strict " "$STATE/codesign.log"
    [[ "$output" == *"SHA-1:     $hash"* ]] || return 1
    [[ "$output" == *"certificate leaf = H\"$(tr 'A-F' 'a-f' <<< "$hash")\""* ]]
}

@test "writes Config/Local.xcconfig and prints the CI secret commands without running them" {
    run "$SCRIPT" --dir "$SIGNING_DIR"
    [ "$status" -eq 0 ]
    diff "$REPO/Config/Local.xcconfig" - << 'EOF'
// Written by scripts/make-signing-identity.sh. Never commit this file.
CODE_SIGN_IDENTITY = RoomForMac Self-Signed
EOF
    [[ "$output" == *"gh secret set RFM_SIGNING_P12_BASE64 < \"$SIGNING_DIR/identity.p12.base64\""* ]] || return 1
    [[ "$output" == *"gh secret set RFM_SIGNING_P12_PASSWORD < \"$SIGNING_DIR/identity.p12.password\""* ]] || return 1
    [[ "$output" != *"not git-ignored"* ]] || return 1
    [ ! -e "$STATE/gh.log" ]
}

@test "an existing Config/Local.xcconfig is left alone" {
    printf 'CODE_SIGN_IDENTITY = -\n' > "$REPO/Config/Local.xcconfig"
    run "$SCRIPT" --dir "$SIGNING_DIR"
    [ "$status" -eq 0 ]
    [ "$(cat "$REPO/Config/Local.xcconfig")" = "CODE_SIGN_IDENTITY = -" ]
    [[ "$output" == *"$REPO/Config/Local.xcconfig already exists and was left alone"* ]]
}

@test "warns when Config/Local.xcconfig is not git-ignored" {
    rm "$REPO/.gitignore"
    run "$SCRIPT" --dir "$SIGNING_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"warning: $REPO/Config/Local.xcconfig is not git-ignored"* ]]
}

@test "--no-import only writes files, and a later run restores that same certificate" {
    run "$SCRIPT" --no-import --dir "$SIGNING_DIR"
    [ "$status" -eq 0 ]
    [ -f "$SIGNING_DIR/key.pem" ]
    [ -f "$SIGNING_DIR/identity.p12.base64" ]
    [ ! -e "$STATE/security.log" ]
    [ ! -e "$STATE/codesign.log" ]
    [ ! -e "$REPO/Config/Local.xcconfig" ]
    local before
    before="$(cert_hash)"
    rm "$STATE/openssl.log"
    chmod 755 "$SIGNING_DIR"
    chmod 644 "$SIGNING_DIR/key.pem"
    run "$SCRIPT" --dir "$SIGNING_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"reusing the key and certificate in $SIGNING_DIR"* ]] || return 1
    [ "$(stat -f %Lp "$SIGNING_DIR")" = 700 ]
    [ "$(stat -f %Lp "$SIGNING_DIR/key.pem")" = 600 ]
    [ "$(cert_hash)" = "$before" ]
    [ "$(cat "$STATE/identities")" = "$before|RoomForMac Self-Signed" ]
    run grep -c -e '^req' -e '^pkcs12' "$STATE/openssl.log"
    [ "$output" = 0 ]
}

@test "a restored certificate with another name is refused" {
    run "$SCRIPT" --no-import --dir "$SIGNING_DIR"
    [ "$status" -eq 0 ]
    run "$SCRIPT" --name "RoomForMac Dev" --dir "$SIGNING_DIR"
    [ "$status" -eq 2 ]
    [[ "$output" == *"$SIGNING_DIR/cert.pem is CN=RoomForMac Self-Signed, not CN=RoomForMac Dev"* ]] || return 1
    run grep -c '^import' "$STATE/security.log"
    [ "$output" = 0 ]
}

@test "a new certificate with another subject is deleted before the keychain changes" {
    run env STUB_CN='RoomForMac Self-Signed (mangled)' "$SCRIPT" --dir "$SIGNING_DIR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"error: openssl wrote a certificate for CN=RoomForMac Self-Signed (mangled), not CN=RoomForMac Self-Signed"* ]] || return 1
    [ ! -e "$SIGNING_DIR/key.pem" ]
    [ ! -e "$SIGNING_DIR/cert.pem" ]
    [ ! -e "$SIGNING_DIR/identity.p12" ]
    [ ! -e "$STATE/codesign.log" ]
    [ ! -e "$STATE/identities" ]
    [ ! -e "$REPO/Config/Local.xcconfig" ]
    diff "$STATE/security.log" - << 'EOF'
find-identity -p codesigning
list-keychains -d user
EOF
    run "$SCRIPT" --dir "$SIGNING_DIR"
    [ "$status" -eq 0 ]
    [ "$(cat "$STATE/identities")" = "$(cert_hash)|RoomForMac Self-Signed" ]
}

@test "a keychain missing from the search list is refused before anything is created" {
    : > "$TMP/other.keychain-db"
    run "$SCRIPT" --keychain "$TMP/other.keychain-db" --dir "$SIGNING_DIR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not on the keychain search list"* ]] || return 1
    [ ! -e "$SIGNING_DIR" ]
}

@test "a denied probe signature fails with a hint" {
    run env STUB_CODESIGN_FAIL=1 "$SCRIPT" --dir "$SIGNING_DIR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"error: codesign could not sign with \"RoomForMac Self-Signed\""* ]] || return 1
    [ ! -e "$REPO/Config/Local.xcconfig" ]
}

@test "a probe signature without a certificate leaf requirement fails" {
    run env STUB_DR='cdhash H"0123456789abcdef0123456789abcdef01234567"' "$SCRIPT" --dir "$SIGNING_DIR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"error: unexpected designated requirement: cdhash H"* ]] || return 1
    [ ! -e "$REPO/Config/Local.xcconfig" ]
}
