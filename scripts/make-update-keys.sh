#!/bin/bash
# Create, once, the EdDSA key that signs RoomForMac's Sparkle updates. Every
# installed copy carries the public half (SUPublicEDKey, from
# RFM_SPARKLE_PUBLIC_KEY in Config/Distribution.xcconfig) and accepts an update
# only if its archive was signed with the private half.
#
# The private key lives in the login keychain, under the account "roomformac"
# (generate_keys --account roomformac). Its seed is exported to
# ~/.roomformac/updates/ed25519.key, outside the repository, so the owner can
# back it up and put it in the GitHub secret SPARKLE_ED_PRIVATE_KEY, which
# release.yml hands to generate_appcast on stdin. docs/releasing.md explains
# what losing the seed, the certificate or both means.
#
# This script never prints the seed and never runs gh.

set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
XCCONFIG="$ROOT/Config/Distribution.xcconfig"
ACCOUNT="roomformac"
DIR="$HOME/.roomformac/updates"
CHECK_ONLY=0
EDIT_TMP=""
EXPORT_DIR=""

# generate_keys is called through this variable, so the bats tests can put a stub
# there. Empty means the copy in Sparkle's Swift package artifact (lib/sparkle.sh).
GENERATE_KEYS="${GENERATE_KEYS:-}"

usage() {
    cat << 'EOF'
Usage: scripts/make-update-keys.sh [--account NAME] [--dir DIR] [--check] [--help]

Creates the EdDSA key that signs RoomForMac's Sparkle updates, writes its public
key into Config/Distribution.xcconfig (RFM_SPARKLE_PUBLIC_KEY) and exports its
seed for CI. See docs/releasing.md. Build the app once first, so Swift Package
Manager fetches Sparkle and its generate_keys tool.

  --account NAME  keychain account for generate_keys (default: roomformac)
  --dir DIR       where ed25519.key is exported (default: ~/.roomformac/updates;
                  must be outside the repository)
  --check         read-only: print the keychain's public key when it matches
                  RFM_SPARKLE_PUBLIC_KEY, and exit 1 when it does not or when
                  there is no key
  --help          show this help

GENERATE_KEYS overrides the generate_keys tool.

Exit status: 0 done; 1 a step failed, or --check found no key or a mismatch;
2 bad usage, or a refusal (Config/Distribution.xcconfig or DIR already holds a
different key or seed, or DIR is inside the repository).

The first keychain access shows a macOS dialog: enter your login password and
click "Always Allow". The terminal never asks for anything.
EOF
}

usage_error() {
    printf 'error: %s\n' "$*" >&2
    printf 'Run scripts/make-update-keys.sh --help for usage.\n' >&2
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

cleanup() {
    if [[ -n "$EDIT_TMP" ]]; then
        rm -f "$EDIT_TMP"
    fi
    if [[ -n "$EXPORT_DIR" ]]; then
        rm -rf "$EXPORT_DIR"
    fi
}
trap cleanup EXIT

need_value() {
    if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
        usage_error "$1 needs a value"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --account)
            need_value "$@"
            ACCOUNT="$2"
            shift 2
            ;;
        --dir)
            need_value "$@"
            DIR="$2"
            shift 2
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

# The account is an argument of every generate_keys call. ASCII only, and the C
# locale keeps the class ASCII in bash 3.2.
valid_account() (
    LC_ALL=C
    case "$1" in
        "" | *[!A-Za-z0-9._-]*) return 1 ;;
    esac
)
valid_account "$ACCOUNT" ||
    usage_error "--account may contain only ASCII letters, digits, dots, dashes and underscores"

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

# The seed must never be committed, so DIR may not be inside the repository.
# Compared without regard to case: the default APFS volume ignores it.
DIR="$(physical_path "$DIR")"
case "$(lower "$DIR")/" in
    "$(lower "$ROOT")"/*) usage_error "--dir must be outside the repository ($ROOT), because anyone with the seed can sign updates that every installed copy accepts" ;;
esac

[[ "$(uname -s)" == Darwin ]] || die "macOS only"
[[ "$(id -u)" -ne 0 ]] || die "run this as your own user, not as root"
[[ -f "$XCCONFIG" ]] || die "$XCCONFIG not found"

# shellcheck source=lib/distribution.sh
source "$ROOT/scripts/lib/distribution.sh"
# distribution_value reports its own error when the key is missing or defined twice.
CONFIGURED="$(distribution_value "$ROOT" RFM_SPARKLE_PUBLIC_KEY)" || exit 1

if [[ -z "$GENERATE_KEYS" ]]; then
    # shellcheck source=lib/sparkle.sh
    source "$ROOT/scripts/lib/sparkle.sh"
    # sparkle_bin reports its own error ("build the app once so Swift Package Manager fetches Sparkle").
    SPARKLE_BIN_DIR="$(sparkle_bin "$ROOT")" || exit 1
    GENERATE_KEYS="$SPARKLE_BIN_DIR/generate_keys"
fi
[[ -x "$GENERATE_KEYS" ]] || die "generate_keys not found or not executable: $GENERATE_KEYS"

# Prints the public key of the keychain account, or nothing when there is none.
# A public key is 32 bytes in base64: 43 characters and one "=". `generate_keys -p`
# fails when the account has no key. Anything that is not such a key, a failure
# or other text alike, counts as "none". Creating should then be harmless even if
# a key exists after all (a denied dialog, say): generate_keys looks the account
# up before it generates anything, and a denied dialog fails the create call too.
keychain_public_key() {
    local answer
    answer="$("$GENERATE_KEYS" --account "$ACCOUNT" -p 2> /dev/null)" || return 0
    printf '%s\n' "$answer" | tr -s '[:space:]' '\n' |
        LC_ALL=C grep -E '^[A-Za-z0-9+/]{43}=$' | head -n 1 || true
}

# Puts $1 on the one RFM_SPARKLE_PUBLIC_KEY line and changes nothing else. The
# file is rewritten in place, so its mode and owner stay as they are.
write_public_key() {
    # shellcheck disable=SC2016 # "$()" is meant literally
    local key="$1" marker='/$()/' text
    # xcconfig reads "//" as the start of a comment, and "/" is a base64 digit, so
    # about one key in a hundred contains it. "$()" expands to nothing in Xcode,
    # and distribution_value removes it: "/$()/" is "//" everywhere that matters.
    text="$key"
    while [[ "$text" == *//* ]]; do
        text="${text//\/\//$marker}"
    done
    EDIT_TMP="$(mktemp "${TMPDIR:-/tmp}/rfm-update-keys.XXXXXX")"
    # The text is base64 characters and "$()": nothing sed would read as syntax.
    sed 's|^\(RFM_SPARKLE_PUBLIC_KEY[[:space:]]*=\).*$|\1 '"$text"'|' "$XCCONFIG" > "$EDIT_TMP"
    cat "$EDIT_TMP" > "$XCCONFIG"
    [[ "$(distribution_value "$ROOT" RFM_SPARKLE_PUBLIC_KEY)" == "$key" ]] ||
        die "$XCCONFIG does not hold the new key after writing it; check it with git diff"
}

if [[ "$CHECK_ONLY" -eq 1 ]]; then
    KEY="$(keychain_public_key)"
    if [[ -z "$KEY" ]]; then
        printf 'no update key for account "%s" in the keychain\n' "$ACCOUNT" >&2
        exit 1
    fi
    if [[ "$CONFIGURED" == "$KEY" ]]; then
        printf '%s matches RFM_SPARKLE_PUBLIC_KEY\n' "$KEY"
        exit 0
    fi
    printf 'mismatch: the keychain account "%s" holds %s, but RFM_SPARKLE_PUBLIC_KEY is %s\n' \
        "$ACCOUNT" "$KEY" "${CONFIGURED:-empty}" >&2
    exit 1
fi

say "reading the keychain account \"$ACCOUNT\" (a macOS dialog may appear: click Always Allow)"
KEY="$(keychain_public_key)"
if [[ -z "$KEY" ]]; then
    # A key that shipped and is missing from this keychain is not replaced by a new one.
    [[ -z "$CONFIGURED" ]] ||
        refuse "Config/Distribution.xcconfig already sets RFM_SPARKLE_PUBLIC_KEY to $CONFIGURED, but the keychain account \"$ACCOUNT\" holds no key; nothing was changed. Restore the seed with generate_keys --account $ACCOUNT -f <file>, or rotate the key as docs/releasing.md describes under \"Rotating the update key\"."
    say "creating the update key"
    if ! CREATE_LOG="$("$GENERATE_KEYS" --account "$ACCOUNT" 2>&1)"; then
        printf '%s\n' "$CREATE_LOG" >&2
        die "generate_keys could not create the update key (was the keychain dialog denied?)"
    fi
    KEY="$(keychain_public_key)"
    [[ -n "$KEY" ]] ||
        die "generate_keys did not report a public key of 44 base64 characters for the account \"$ACCOUNT\"; Config/Distribution.xcconfig was not touched"
fi

if [[ -n "$CONFIGURED" && "$CONFIGURED" != "$KEY" ]]; then
    refuse "Config/Distribution.xcconfig sets RFM_SPARKLE_PUBLIC_KEY to $CONFIGURED, but the keychain account \"$ACCOUNT\" holds $KEY; nothing was changed. Replacing a public key that shipped strands installed copies unless it is rotated: see docs/releasing.md, \"Rotating the update key\"."
fi

# The seed goes to a private folder inside DIR first, so a failed export leaves
# no half-written file at the real path and an existing file can be compared.
SEED_FILE="$DIR/ed25519.key"
mkdir -p "$DIR"
chmod 700 "$DIR"
EXPORT_DIR="$(mktemp -d "$DIR/.export.XXXXXX")"
say "exporting the seed (a macOS dialog may appear again: click Always Allow)"
# The seed is not shown: the tool's stdout is dropped, and its stderr is shown only when it fails.
if ! "$GENERATE_KEYS" --account "$ACCOUNT" -x "$EXPORT_DIR/ed25519.key" > /dev/null 2> "$EXPORT_DIR/stderr"; then
    cat "$EXPORT_DIR/stderr" >&2
    die "generate_keys could not export the seed of the account \"$ACCOUNT\""
fi
[[ -s "$EXPORT_DIR/ed25519.key" ]] || die "generate_keys wrote no seed"
chmod 600 "$EXPORT_DIR/ed25519.key"
if [[ "$(grep -c '' "$EXPORT_DIR/ed25519.key")" -ne 1 ]] ||
    ! LC_ALL=C grep -Eqx '[A-Za-z0-9+/]{43,}={0,2}' "$EXPORT_DIR/ed25519.key"; then
    die "generate_keys wrote something other than one line of base64 to the export file"
fi

if [[ -e "$SEED_FILE" || -L "$SEED_FILE" ]]; then
    [[ -f "$SEED_FILE" && ! -L "$SEED_FILE" ]] || refuse "$SEED_FILE is not a regular file; nothing was changed"
    cmp -s "$SEED_FILE" "$EXPORT_DIR/ed25519.key" ||
        refuse "$SEED_FILE holds a different seed than the keychain account \"$ACCOUNT\"; nothing was changed. Move it away, keeping a copy, if the keychain's key is the one to use."
fi

if [[ -z "$CONFIGURED" ]]; then
    write_public_key "$KEY"
    say "wrote RFM_SPARKLE_PUBLIC_KEY to $XCCONFIG"
else
    say "RFM_SPARKLE_PUBLIC_KEY already holds this key"
fi
if [[ -e "$SEED_FILE" ]]; then
    chmod 600 "$SEED_FILE"
    say "$SEED_FILE already holds this seed"
else
    mv "$EXPORT_DIR/ed25519.key" "$SEED_FILE"
    say "exported the seed to $SEED_FILE"
fi

cat << EOF

Account:     $ACCOUNT
Public key:  $KEY
Seed file:   $SEED_FILE

The public key is not secret: commit Config/Distribution.xcconfig.

CI secret for release builds (run this yourself once the repository is public
and the \`release\` environment exists):
  gh secret set SPARKLE_ED_PRIVATE_KEY --env release < "$SEED_FILE"

Back up $DIR in your password manager, next to ~/.roomformac/signing.
Losing the seed alone is survivable while the signing certificate stays the same;
losing both strands every installed copy (docs/releasing.md).
EOF
