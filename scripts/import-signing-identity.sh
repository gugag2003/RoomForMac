#!/bin/bash
# Import RoomForMac's release signing identity into a throwaway keychain on a
# CI runner (create), and delete that keychain again (delete). release.yml's
# build job is the caller; docs/signing.md explains the identity.
#
#   scripts/import-signing-identity.sh create <keychain-path> >> "$GITHUB_ENV"
#   scripts/import-signing-identity.sh delete <keychain-path>
#
# The secrets come only from the environment and are never printed. The two
# passwords cannot stay out of argv (`create-keychain -p`, `unlock-keychain -p`,
# `set-key-partition-list -k` and `import -P` have no other channel), so this
# belongs on an ephemeral runner, or on a keychain that is thrown away at once.
# stdout carries only the KEY=VALUE lines meant for $GITHUB_ENV; every message
# goes to stderr. Shell tracing is never turned on, because it would print
# every secret.

set -euo pipefail
set +x
umask 077

# The secrets leave the environment before anything else runs, so that no tool
# this script starts, for delete as well as create, inherits them.
P12_BASE64="${RFM_SIGNING_P12_BASE64:-}"
P12_PASSWORD="${RFM_SIGNING_P12_PASSWORD:-}"
unset RFM_SIGNING_P12_BASE64 RFM_SIGNING_P12_PASSWORD

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
DEFAULT_NAME="RoomForMac Self-Signed"
PIN_FILE="$ROOT/Config/signing-identity.sha1"

# Every tool that touches a keychain, makes a password or decodes the secret is
# called through one of these variables, so the bats tests can put stubs there.
SECURITY="${SECURITY:-/usr/bin/security}"
OPENSSL="${OPENSSL:-/usr/bin/openssl}"
BASE64="${BASE64:-/usr/bin/base64}"

usage() {
    cat << 'EOF'
Usage: scripts/import-signing-identity.sh create <keychain-path>
       scripts/import-signing-identity.sh delete <keychain-path>
       scripts/import-signing-identity.sh --help

create  makes a new keychain at <keychain-path>, imports the release signing
        identity into it, puts it first on the user keychain search list and
        checks the identity. On success stdout is exactly two lines, for
        $GITHUB_ENV:
            KEYCHAIN=<keychain-path>
            SIGNING_SHA1=<uppercase SHA-1 of the certificate>
        A keychain that a failed or interrupted run made is deleted again.
delete  takes <keychain-path> off the search list and deletes it. It succeeds
        when the keychain is already gone.

<keychain-path> must end in .keychain-db and lie outside ~/Library/Keychains:
the login keychain is never touched. For create it must not exist yet.

Environment (create):
  RFM_SIGNING_P12_BASE64     the PKCS#12 identity, base64 (required)
  RFM_SIGNING_P12_PASSWORD   its password (required)
  RFM_SIGNING_IDENTITY_NAME  the identity's name (default: "RoomForMac Self-Signed")
  RFM_SIGNING_EXPECTED_SHA1  the certificate's SHA-1 (default: the contents of
                             Config/signing-identity.sha1 when that exists;
                             an empty value skips the check)
  SECURITY, OPENSSL, BASE64  the tools (default: /usr/bin/security,
                             /usr/bin/openssl, /usr/bin/base64)

Exit status: 0 done; 1 a step failed (a keychain that create made is deleted
again); 2 bad usage or a refusal.

A throwaway identity, as the hardened-runtime spike and the update rehearsal
use it (the login keychain is never involved):
  scripts/make-signing-identity.sh --no-import --name "RoomForMac Spike" --dir "$TMPDIR/rfm-spike"
  export RFM_SIGNING_P12_BASE64="$(cat "$TMPDIR/rfm-spike/identity.p12.base64")"
  export RFM_SIGNING_P12_PASSWORD="$(cat "$TMPDIR/rfm-spike/identity.p12.password")"
  export RFM_SIGNING_IDENTITY_NAME="RoomForMac Spike"
  export RFM_SIGNING_EXPECTED_SHA1=   # the committed pin is the real identity's
  scripts/import-signing-identity.sh create "$TMPDIR/rfm-spike.keychain-db"
  ...build with CODE_SIGN_IDENTITY="RoomForMac Spike" OTHER_CODE_SIGN_FLAGS="--keychain <KEYCHAIN>"...
  scripts/import-signing-identity.sh delete "$TMPDIR/rfm-spike.keychain-db"
EOF
}

usage_error() {
    printf 'error: %s\n' "$*" >&2
    printf 'Run scripts/import-signing-identity.sh --help for usage.\n' >&2
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
say() { printf '==> %s\n' "$*" >&2; }

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# NAME goes into an awk pattern, so it is ASCII only, with no space at either
# end. The C locale keeps the class ASCII (make-signing-identity.sh explains).
valid_name() (
    LC_ALL=C
    case "$1" in
        "" | " "* | *" " | *[!A-Za-z0-9\ ._-]*) return 1 ;;
    esac
)

# Physical absolute path of $1, which need not exist yet: the deepest existing
# folder is resolved with pwd -P and the rest is appended. A '..' in the part
# that does not exist yet cannot be resolved, so it is refused.
physical_path() {
    local path="$1" rest="" leaf resolved
    [[ "$path" == /* ]] || path="$PWD/$path"
    while [[ ! -d "$path" ]]; do
        leaf="$(basename "$path")"
        [[ "$leaf" != ".." ]] || refuse "the keychain path must not contain '..' in a part that does not exist yet: $1"
        rest="/$leaf$rest"
        path="$(dirname "$path")"
    done
    resolved="$(cd "$path" && pwd -P)" || refuse "cannot enter the folder $path"
    [[ "$resolved" != / ]] || resolved=""
    printf '%s%s\n' "$resolved" "$rest"
}

count_lines() {
    if [[ -z "$1" ]]; then
        echo 0
    else
        printf '%s\n' "$1" | wc -l | tr -d ' '
    fi
}

is_sha1() {
    [[ "${#1}" -eq 40 && "$1" != *[!0-9A-Fa-f]* ]]
}

# The user keychain search list, as an array. Sets LIST_FOUND to 1 when
# $KEYCHAIN is on it, and LIST_REST to the other entries in their order. The
# tool prints each path in quotes, and a path may hold spaces.
read_search_list() {
    local listing entry
    LIST_FOUND=0
    LIST_REST=()
    listing="$("$SECURITY" list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')" || return 1
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        if [[ "$entry" == "$KEYCHAIN" ]]; then
            LIST_FOUND=1
        else
            LIST_REST+=("$entry")
        fi
    done <<< "$listing"
}

# Takes $KEYCHAIN off the user search list, keeping every other entry in order,
# then deletes it. Nothing is an error when the keychain is already gone.
# Returns 1, after saying why, when an existing keychain cannot be deleted.
forget_keychain() {
    if read_search_list; then
        if [[ "$LIST_FOUND" -eq 1 && "${#LIST_REST[@]}" -gt 0 ]]; then
            "$SECURITY" list-keychains -d user -s "${LIST_REST[@]}" > /dev/null ||
                printf 'warning: could not update the keychain search list\n' >&2
        fi
    else
        printf 'warning: could not read the keychain search list\n' >&2
    fi
    if [[ -e "$KEYCHAIN" ]]; then
        if ! "$SECURITY" delete-keychain "$KEYCHAIN" >&2 && [[ -e "$KEYCHAIN" ]]; then
            printf 'error: could not delete %s\n' "$KEYCHAIN" >&2
            return 1
        fi
    fi
}

for argument in "$@"; do
    case "$argument" in
        -h | --help)
            usage
            exit 0
            ;;
    esac
done

case "${1:-}" in
    create | delete) ACTION="$1" ;;
    "") usage_error "missing action: create or delete" ;;
    *) usage_error "unknown action: $1" ;;
esac
[[ $# -eq 2 ]] || usage_error "$ACTION needs exactly one argument, the keychain path"
KEYCHAIN_ARG="$2"

[[ -n "$KEYCHAIN_ARG" ]] || usage_error "the keychain path is empty"
case "$KEYCHAIN_ARG" in
    *[[:cntrl:]]*) usage_error "the keychain path contains a control character" ;;
    *.keychain-db) ;;
    *) refuse "the keychain path must end in .keychain-db: $KEYCHAIN_ARG" ;;
esac

# An absolute, physical path, so that the file this script checks, prints and
# deletes is the file `security` makes: a relative name would land in
# ~/Library/Keychains, and a name without the suffix would get one added.
KEYCHAIN="$(physical_path "$KEYCHAIN_ARG")"
case "$KEYCHAIN" in
    *[[:cntrl:]]*) usage_error "the keychain path contains a control character after resolving symbolic links" ;;
esac
for protected in "${HOME:?}/Library/Keychains" /Library/Keychains /System/Library/Keychains; do
    folder="$(physical_path "$protected")"
    case "$(lower "$KEYCHAIN")/" in
        "$(lower "$folder")"/*) refuse "$KEYCHAIN is inside $folder: this script handles only a throwaway keychain, never the login or a system keychain" ;;
    esac
done

# physical_path resolves the folder but not the last part, and `security` would
# follow a link there: delete-keychain on a link to the login keychain removes it.
[[ ! -L "$KEYCHAIN" ]] ||
    refuse "$KEYCHAIN is a symbolic link: this script handles only a keychain file of its own making"

[[ -x "$SECURITY" ]] || die "$SECURITY not found"

if [[ "$ACTION" == delete ]]; then
    if [[ -e "$KEYCHAIN" ]]; then
        say "deleting the keychain $KEYCHAIN"
    else
        say "the keychain $KEYCHAIN is already gone"
    fi
    forget_keychain || exit 1
    exit 0
fi

# --- create -----------------------------------------------------------------

[[ -n "$P12_BASE64" ]] ||
    refuse "RFM_SIGNING_P12_BASE64 is not set; it is a secret of the release environment (docs/signing.md, \"CI secrets\")"
[[ -n "$P12_PASSWORD" ]] ||
    refuse "RFM_SIGNING_P12_PASSWORD is not set; it is a secret of the release environment (docs/signing.md, \"CI secrets\")"

NAME="${RFM_SIGNING_IDENTITY_NAME-$DEFAULT_NAME}"
valid_name "$NAME" ||
    usage_error "RFM_SIGNING_IDENTITY_NAME may contain only ASCII letters, digits, spaces (not at either end), dots, dashes and underscores"

# The pin: the certificate the release must be signed with. An empty
# RFM_SIGNING_EXPECTED_SHA1 skips the check on purpose (a throwaway identity);
# a pin file that exists but is not a SHA-1 is an error, never a silent skip.
SKIP_REASON=""
if [[ -n "${RFM_SIGNING_EXPECTED_SHA1+set}" ]]; then
    EXPECTED="$RFM_SIGNING_EXPECTED_SHA1"
    EXPECTED_SOURCE="RFM_SIGNING_EXPECTED_SHA1"
    [[ -n "$EXPECTED" ]] || SKIP_REASON="RFM_SIGNING_EXPECTED_SHA1 is empty"
elif [[ -f "$PIN_FILE" ]]; then
    EXPECTED="$(tr -d '[:space:]' < "$PIN_FILE")"
    EXPECTED_SOURCE="Config/signing-identity.sha1"
else
    EXPECTED=""
    EXPECTED_SOURCE=""
    SKIP_REASON="Config/signing-identity.sha1 does not exist"
fi
if [[ -n "$SKIP_REASON" ]]; then
    printf 'warning: the certificate SHA-1 is not checked (%s)\n' "$SKIP_REASON" >&2
elif ! is_sha1 "$EXPECTED"; then
    refuse "$EXPECTED_SOURCE must hold exactly 40 hex digits"
fi

[[ -x "$OPENSSL" ]] || die "$OPENSSL not found"
[[ -x "$BASE64" ]] || die "$BASE64 not found"
[[ ! -e "$KEYCHAIN" && ! -L "$KEYCHAIN" ]] ||
    refuse "$KEYCHAIN already exists; this script never modifies an existing keychain"
[[ -d "$(dirname "$KEYCHAIN")" ]] || refuse "the folder $(dirname "$KEYCHAIN") does not exist"

WORK=""
MADE=0
# On any exit: remove the decoded PKCS#12, and when a run that failed or was
# interrupted has made the keychain, delete it again. A signal ends the script
# through `exit 1`, so this runs for it too (bash skips an EXIT trap when a
# signal kills it).
cleanup() {
    local status=$?
    trap - EXIT
    trap '' HUP INT TERM
    if [[ -n "$WORK" ]]; then
        rm -rf "$WORK"
    fi
    if [[ "$MADE" -eq 1 && "$status" -ne 0 ]]; then
        say "removing the keychain that this run made"
        forget_keychain || true
    fi
    [[ "$status" -eq 0 || "$status" -eq 2 ]] || status=1
    exit "$status"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

# 1. The keychain password: random, kept in a variable, never printed.
KEYCHAIN_PASSWORD="$("$OPENSSL" rand -hex 24)" || die "openssl could not make a keychain password"
[[ "${#KEYCHAIN_PASSWORD}" -eq 48 && "$KEYCHAIN_PASSWORD" != *[!0-9A-Fa-f]* ]] ||
    die "openssl rand did not return 24 random bytes as hex"

# 2. The PKCS#12, decoded into a private folder that the trap removes. The
# secret reaches base64 through stdin, not argv, and macOS's base64 accepts
# any input, so an empty result is the failure to look for.
TEMP_ROOT="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "${TEMP_ROOT%/}/rfm-import.XXXXXX")"
printf '%s' "$P12_BASE64" | "$BASE64" --decode > "$WORK/identity.p12" ||
    die "RFM_SIGNING_P12_BASE64 could not be decoded"
unset P12_BASE64
[[ -s "$WORK/identity.p12" ]] || die "RFM_SIGNING_P12_BASE64 decoded to nothing"

# 3. The keychain: it stays unlocked for six hours, longer than a release build.
say "making the temporary keychain $KEYCHAIN"
# A signal that arrives while create-keychain runs is only recorded, so that the
# keychain it made is known (MADE=1) before the script exits and the trap deletes it.
INTERRUPTED=0
trap 'INTERRUPTED=1' HUP INT TERM
"$SECURITY" create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >&2 || die "security create-keychain failed"
MADE=1
trap 'exit 1' HUP INT TERM
[[ "$INTERRUPTED" -eq 0 ]] || exit 1
"$SECURITY" set-keychain-settings -lut 21600 "$KEYCHAIN" >&2 || die "security set-keychain-settings failed"
"$SECURITY" unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >&2 || die "security unlock-keychain failed"

# 4. The import: only /usr/bin/codesign may use the key without asking, never
# -A (any application), and no trust settings.
say "importing the signing identity \"$NAME\""
"$SECURITY" import "$WORK/identity.p12" -k "$KEYCHAIN" -f pkcs12 -P "$P12_PASSWORD" -T /usr/bin/codesign >&2 ||
    die "security import failed (does RFM_SIGNING_P12_PASSWORD belong to RFM_SIGNING_P12_BASE64?)"
unset P12_PASSWORD
rm -f "$WORK/identity.p12"

# 5. Without the partition list, codesign would wait for a click that no CI
# runner can give. The tool lists every key it changes, which is noise.
"$SECURITY" set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" > /dev/null ||
    die "security set-key-partition-list failed"
unset KEYCHAIN_PASSWORD

# 6. The search list: codesign and embed-engine.sh find the identity through it,
# because they pass no --keychain. The new keychain goes first and the others
# keep their order. `create-keychain` may have added it already, so it is
# dropped from the rest of the list.
read_search_list || die "security list-keychains failed"
"$SECURITY" list-keychains -d user -s "$KEYCHAIN" ${LIST_REST[@]+"${LIST_REST[@]}"} > /dev/null ||
    die "security list-keychains -s failed"

# 7. The identity. No -v: it would hide an untrusted self-signed certificate.
LISTING="$("$SECURITY" find-identity -p codesigning "$KEYCHAIN")" || die "security find-identity failed"
HASHES="$(printf '%s\n' "$LISTING" |
    awk -v want="\"$NAME\"" 'length($2) == 40 && $2 ~ /^[0-9A-Fa-f]+$/ && index($0, $2 " " want) { print toupper($2) }' |
    sort -u)"
COUNT="$(count_lines "$HASHES")"
if [[ "$COUNT" -ne 1 ]]; then
    printf '%s\n' "$LISTING" >&2
    die "expected one identity named \"$NAME\" in the keychain, found $COUNT"
fi
if [[ -z "$SKIP_REASON" && "$(lower "$HASHES")" != "$(lower "$EXPECTED")" ]]; then
    die "the identity \"$NAME\" has SHA-1 $HASHES, but $EXPECTED_SOURCE says $(printf '%s' "$EXPECTED" | tr '[:lower:]' '[:upper:]'); the secrets hold another certificate than the expected one"
fi

say "the identity \"$NAME\" is ready (SHA-1 $HASHES)"
printf 'KEYCHAIN=%s\nSIGNING_SHA1=%s\n' "$KEYCHAIN" "$HASHES"
