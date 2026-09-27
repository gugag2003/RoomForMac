#!/bin/bash
# Create, once per Mac, the stable self-signed code-signing identity that
# RoomForMac builds are signed with, so Full Disk Access and Automation grants
# survive rebuilds. docs/signing.md explains why, and what to back up.
#
# An ad-hoc signature's designated requirement (DR) is the build's cdhash, which
# changes on every build. A certificate signature's DR names the certificate:
#   identifier "com.roomformac.RoomForMac" and certificate leaf = H"<SHA-1 of the certificate>"
# That stays the same across rebuilds and releases. The certificate gets no
# trust settings: codesign and Xcode sign with an untrusted self-signed
# identity, and a DR check compares the certificate hash, not trust.

set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
LOCAL_XCCONFIG="$ROOT/Config/Local.xcconfig"
NAME="RoomForMac Self-Signed"
DIR="$HOME/.roomformac/signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
DAYS=7300 # 20 years: a new certificate means a new DR, and every user re-grants
PROBE_IDENTIFIER="com.roomformac.signing-probe"
CHECK_ONLY=0
IMPORT=1

# Every tool that makes keys, reads or changes the keychain, or signs is called
# through one of these variables, so the bats tests can put stubs there.
# /usr/bin/openssl is LibreSSL; Homebrew's OpenSSL 3 usually comes first on PATH.
OPENSSL="${OPENSSL:-/usr/bin/openssl}"
SECURITY="${SECURITY:-/usr/bin/security}"
CODESIGN="${CODESIGN:-/usr/bin/codesign}"

usage() {
    cat << 'EOF'
Usage: scripts/make-signing-identity.sh [--name NAME] [--dir DIR] [--keychain PATH] [--no-import] [--check] [--help]

Creates the self-signed code-signing identity RoomForMac builds are signed with,
imports it into your keychain, checks that codesign can use it, and writes
Config/Local.xcconfig. See docs/signing.md.

  --name NAME      certificate common name (default: "RoomForMac Self-Signed")
  --dir DIR        where key.pem, cert.pem and the CI export live
                   (default: ~/.roomformac/signing; must be outside the repository).
                   If DIR already holds key.pem and cert.pem, they are imported
                   instead of creating a new certificate.
  --keychain PATH  keychain to import into (default: the login keychain)
  --no-import      only create the files in DIR; the keychain is not touched
  --check          read-only: print '<SHA-1> "NAME"' when exactly one identity exists
  --help           show this help

Exit status: 0 done; 1 no identity (--check) or a step failed;
2 bad usage, more than one identity, or a refusal (an identity with NAME
already exists, or DIR holds a different certificate).

The first signature shows a macOS dialog: enter your login password and click
"Always Allow". The terminal never asks for anything.
EOF
}

usage_error() {
    printf 'error: %s\n' "$*" >&2
    printf 'Run scripts/make-signing-identity.sh --help for usage.\n' >&2
    exit 2
}
refuse() {
    printf 'error: %s\n' "$*" >&2
    exit 2
}
die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}
say() { printf '==> %s\n' "$*"; }

need_value() {
    if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
        usage_error "$1 needs a value"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)
            need_value "$@"
            NAME="$2"
            shift 2
            ;;
        --dir)
            need_value "$@"
            DIR="$2"
            shift 2
            ;;
        --keychain)
            need_value "$@"
            KEYCHAIN="$2"
            shift 2
            ;;
        --no-import)
            IMPORT=0
            shift
            ;;
        --check)
            CHECK_ONLY=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) usage_error "unknown argument: $1" ;;
    esac
done

# NAME ends up in openssl.cnf, an awk pattern and Local.xcconfig.
case "$NAME" in
    *[![:alnum:]\ ._-]*) usage_error "--name may contain only letters, digits, spaces, dots, dashes and underscores" ;;
esac

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Physical absolute path of $1, which need not exist yet: the deepest existing
# folder is resolved with pwd -P and the rest is appended. A '..' in the part
# that does not exist yet cannot be resolved, so it is refused.
physical_path() {
    local path="$1" rest="" leaf
    [[ "$path" == /* ]] || path="$PWD/$path"
    while [[ ! -d "$path" ]]; do
        leaf="$(basename "$path")"
        [[ "$leaf" != ".." ]] || usage_error "--dir must not contain '..' in a part that does not exist yet: $1"
        rest="/$leaf$rest"
        path="$(dirname "$path")"
    done
    printf '%s%s\n' "$(cd "$path" && pwd -P)" "$rest"
}

# The key must never be committed, so DIR may not be inside the repository.
# Compared without regard to case: the default APFS volume ignores it.
DIR="$(physical_path "$DIR")"
case "$(lower "$DIR")/" in
    "$(lower "$ROOT")"/*) usage_error "--dir must be outside the repository ($ROOT), because anyone with the key can sign code that inherits RoomForMac's grants" ;;
esac

# SHA-1s (uppercase, unique, one per line) of the code-signing identities named
# exactly NAME in the keychain search list, which codesign and Xcode search.
# No -v: it lists only identities with a trusted certificate, and this one is
# deliberately untrusted. A trusted identity is listed twice, hence sort -u.
identity_hashes() {
    local listing
    listing="$("$SECURITY" find-identity -p codesigning)" || die "security find-identity failed"
    printf '%s\n' "$listing" |
        awk -v want="\"$NAME\"" '
            length($2) == 40 && $2 ~ /^[0-9A-Fa-f]+$/ && index($0, $2 " " want) { print toupper($2) }
        ' | sort -u
}
count_lines() {
    if [[ -z "$1" ]]; then
        echo 0
    else
        printf '%s\n' "$1" | wc -l | tr -d ' '
    fi
}
cert_sha1() {
    "$OPENSSL" x509 -in "$1" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g' | tr '[:lower:]' '[:upper:]'
}
cert_subject() {
    "$OPENSSL" x509 -in "$1" -noout -subject -nameopt RFC2253 | sed 's/^subject= *//'
}

[[ "$(uname -s)" == Darwin ]] || die "macOS only"
[[ "$(id -u)" -ne 0 ]] || die "run this as your own user, not as root"

if [[ "$CHECK_ONLY" -eq 1 ]]; then
    HASHES="$(identity_hashes)"
    COUNT="$(count_lines "$HASHES")"
    case "$COUNT" in
        0)
            printf 'no identity named "%s"\n' "$NAME" >&2
            exit 1
            ;;
        1)
            printf '%s "%s"\n' "$HASHES" "$NAME"
            exit 0
            ;;
        *)
            printf 'ambiguous: %s identities named "%s":\n%s\n' "$COUNT" "$NAME" "$HASHES" >&2
            exit 2
            ;;
    esac
fi

[[ -x "$OPENSSL" ]] || die "$OPENSSL not found"

if [[ "$IMPORT" -eq 1 ]]; then
    HASHES="$(identity_hashes)"
    COUNT="$(count_lines "$HASHES")"
    if [[ "$COUNT" -eq 1 ]]; then
        refuse "the keychain already holds an identity named \"$NAME\" ($HASHES); nothing was changed. --check prints it, and docs/signing.md explains how to replace it."
    elif [[ "$COUNT" -gt 1 ]]; then
        printf 'error: %s identities named "%s"; codesign cannot choose between them:\n%s\n' \
            "$COUNT" "$NAME" "$HASHES" >&2
        refuse "keep one: delete the others in Keychain Access (login > My Certificates)"
    fi
    [[ -f "$KEYCHAIN" ]] || die "keychain not found: $KEYCHAIN"
    SEARCH_LIST="$("$SECURITY" list-keychains -d user)" || die "security list-keychains failed"
    grep -qF "\"$KEYCHAIN\"" <<< "$SEARCH_LIST" ||
        die "$KEYCHAIN is not on the keychain search list, so codesign and Xcode would not see it"
fi

mkdir -p "$DIR"
chmod 700 "$DIR"

if [[ -f "$DIR/key.pem" && -f "$DIR/cert.pem" ]]; then
    SUBJECT="$(cert_subject "$DIR/cert.pem")"
    [[ "$SUBJECT" == "CN=$NAME" ]] ||
        refuse "$DIR/cert.pem is $SUBJECT, not CN=$NAME; pass the matching --name or another --dir"
    say "reusing the key and certificate in $DIR"
else
    [[ ! -e "$DIR/key.pem" && ! -e "$DIR/cert.pem" ]] ||
        refuse "$DIR holds only one of key.pem and cert.pem; move it away first"
    say "creating a self-signed code-signing certificate \"$NAME\" in $DIR"
    # CN only, no O or OU: the DR then pins `certificate leaf`, and Xcode sees no team.
    cat > "$DIR/openssl.cnf" << EOF
[ req ]
distinguished_name = dn
x509_extensions    = codesign
prompt             = no
[ dn ]
CN = $NAME
[ codesign ]
basicConstraints     = critical, CA:false
keyUsage             = critical, digitalSignature
extendedKeyUsage     = critical, codeSigning
subjectKeyIdentifier = hash
EOF
    "$OPENSSL" req -x509 -new -newkey rsa:2048 -nodes -sha256 -days "$DAYS" \
        -set_serial "0x$("$OPENSSL" rand -hex 16)" \
        -config "$DIR/openssl.cnf" -keyout "$DIR/key.pem" -out "$DIR/cert.pem"
    rm -f "$DIR/identity.p12" "$DIR/identity.p12.base64" "$DIR/identity.p12.password"
fi

if [[ ! -f "$DIR/identity.p12" || ! -f "$DIR/identity.p12.password" ]]; then
    "$OPENSSL" rand -hex 24 > "$DIR/identity.p12.password"
    # PBE-SHA1-3DES and a SHA-1 MAC: `security import` on macOS 14 and older
    # rejects OpenSSL 3's AES/SHA-256 defaults with "MAC verification failed".
    RFM_P12_PASS="$(cat "$DIR/identity.p12.password")" \
        "$OPENSSL" pkcs12 -export -name "$NAME" \
        -inkey "$DIR/key.pem" -in "$DIR/cert.pem" \
        -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
        -passout env:RFM_P12_PASS -out "$DIR/identity.p12"
    rm -f "$DIR/identity.p12.base64"
fi
if [[ ! -f "$DIR/identity.p12.base64" ]]; then
    base64 -i "$DIR/identity.p12" -o "$DIR/identity.p12.base64"
fi
for file in key.pem cert.pem openssl.cnf identity.p12 identity.p12.base64 identity.p12.password; do
    if [[ -e "$DIR/$file" ]]; then
        chmod 600 "$DIR/$file"
    fi
done

HASH="$(cert_sha1 "$DIR/cert.pem")"
DR="(no probe signature: --no-import)"

if [[ "$IMPORT" -eq 1 ]]; then
    say "importing \"$NAME\" into $KEYCHAIN (a dialog appears only if that keychain is locked)"
    # -x: the private key cannot be exported from the keychain again; DIR keeps the copy.
    # -T: codesign may use the key. No trust settings are added.
    "$SECURITY" import "$DIR/identity.p12" -k "$KEYCHAIN" -f pkcs12 \
        -P "$(cat "$DIR/identity.p12.password")" -x -T /usr/bin/codesign

    HASHES="$(identity_hashes)"
    [[ "$(count_lines "$HASHES")" -eq 1 ]] ||
        die "after the import, expected one identity named \"$NAME\", found: ${HASHES:-none}"
    [[ "$HASHES" == "$HASH" ]] || die "the imported identity $HASHES is not $DIR/cert.pem ($HASH)"

    say "probe signature (the first time, a dialog asks for your login password: click Always Allow)"
    TEMP_ROOT="${TMPDIR:-/tmp}"
    PROBE_DIR="$(mktemp -d "${TEMP_ROOT%/}/rfm-signing-probe.XXXXXX")"
    trap 'rm -rf "$PROBE_DIR"' EXIT
    cp /usr/bin/true "$PROBE_DIR/probe"
    if ! SIGN_LOG="$("$CODESIGN" --force --timestamp=none --identifier "$PROBE_IDENTIFIER" \
        --sign "$HASH" "$PROBE_DIR/probe" 2>&1)"; then
        printf '%s\n' "$SIGN_LOG" >&2
        die "codesign could not sign with \"$NAME\" (was the dialog denied, or is the keychain locked?)"
    fi
    "$CODESIGN" --verify --strict "$PROBE_DIR/probe" || die "the probe signature does not verify"
    DR="$("$CODESIGN" -d -r- "$PROBE_DIR/probe" 2> /dev/null | sed -n 's/^designated => //p' || true)"
    case "$(lower "$DR")" in
        *"certificate leaf = h\"$(lower "$HASH")\""*) ;;
        *) die "unexpected designated requirement: ${DR:-none} (expected certificate leaf = H\"$HASH\")" ;;
    esac

    if [[ ! -d "$(dirname "$LOCAL_XCCONFIG")" ]]; then
        say "no Config folder in $ROOT; put CODE_SIGN_IDENTITY = $NAME in Config/Local.xcconfig yourself"
    elif [[ -e "$LOCAL_XCCONFIG" ]]; then
        say "$LOCAL_XCCONFIG already exists and was left alone; it must say CODE_SIGN_IDENTITY = $NAME"
    else
        printf '// Written by scripts/make-signing-identity.sh. Never commit this file.\nCODE_SIGN_IDENTITY = %s\n' \
            "$NAME" > "$LOCAL_XCCONFIG"
        chmod 644 "$LOCAL_XCCONFIG"
        say "wrote $LOCAL_XCCONFIG"
    fi
    if [[ -e "$LOCAL_XCCONFIG" ]] && ! git -C "$ROOT" check-ignore -q "$LOCAL_XCCONFIG" 2> /dev/null; then
        printf 'warning: %s is not git-ignored; never commit it\n' "$LOCAL_XCCONFIG" >&2
    fi
else
    say "files only (--no-import): the keychain was not touched"
fi

cat << EOF

Identity:  $NAME
SHA-1:     $HASH
Probe DR:  $DR
App DR:    identifier "com.roomformac.RoomForMac" and certificate leaf = H"$(lower "$HASH")"

Back up the whole folder $DIR in your password manager.
Losing it means a new certificate, and every user granting Full Disk Access
and Automation again.

CI secrets for release builds (run these yourself when a workflow needs them):
  gh secret set RFM_SIGNING_P12_BASE64 < "$DIR/identity.p12.base64"
  gh secret set RFM_SIGNING_P12_PASSWORD < "$DIR/identity.p12.password"
EOF
