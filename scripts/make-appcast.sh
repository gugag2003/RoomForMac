#!/bin/bash
# Add one release to the Sparkle appcast and check the result before anything
# is published. release.yml runs it once per tag (Task 13); the update
# rehearsal runs it against a local server (Task 15).
#
# The appcast exists only as a release asset (Ruling 3): the previous release's
# appcast.xml goes in with --previous, Sparkle's generate_appcast adds one item
# for the new archive, and every earlier item must come out exactly as it went
# in. The EdDSA key reaches Sparkle's tools only on their standard input: never
# in argv, never in a file, never printed. Every failure stops the script at
# once, and --out is written only after every check has passed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/distribution.sh
source "$ROOT/scripts/lib/distribution.sh"
# shellcheck source=lib/version.sh
source "$ROOT/scripts/lib/version.sh"
# shellcheck source=lib/sparkle.sh
source "$ROOT/scripts/lib/sparkle.sh"

# The lowest macOS this release runs on. release-summary.sh states the same
# value for the site, and check-release-app.sh pins LSMinimumSystemVersion.
MINIMUM_MACOS="26.0"
# generate_appcast keeps this many items. The newest KEEP_EARLIER earlier items
# must survive a release; older ones may be dropped.
MAXIMUM_VERSIONS=10
KEEP_EARLIER=$((MAXIMUM_VERSIONS - 1))

usage() {
    cat << 'EOF'
Usage: scripts/make-appcast.sh --archive <RoomForMac-X.Y.Z.tar.xz> --notes <release-notes/X.Y.Z.md>
           --tag vX.Y.Z --out <appcast.xml> [--previous <appcast.xml>] [--repository OWNER/NAME]
           [--download-url-prefix URL] [--link URL]

Adds the release to the appcast with Sparkle's generate_appcast and checks the
result: the new item's build, version, enclosure URL, length, EdDSA signature,
minimum macOS and embedded notes; that no item asks for particular hardware;
that every earlier item is byte for byte what --previous held; and that
sign_update verifies the archive against the signature. --out is written only
if all of that passes.

  --previous               the appcast of the latest release (none before the first release)
  --repository             defaults to RFM_REPOSITORY in Config/Distribution.xcconfig
  --download-url-prefix    defaults to https://github.com/<repository>/releases/download/<tag>/
                           (https, or http on 127.0.0.1 or localhost for the rehearsal)
  --link                   defaults to RFM_SITE_URL and a slash

Environment:
  SPARKLE_ED_PRIVATE_KEY   required: the base64 EdDSA seed
  SPARKLE_BIN              Sparkle's bin folder (default: found by lib/sparkle.sh)
  GENERATE_APPCAST, SIGN_UPDATE   the two tools, when not in that folder

Exit status: 0 done; 1 a check failed (a tag that is not a strict vX.Y.Z, an
archive named for another version, a build that is not above every published
one, or any check on the generated feed); 2 usage error (a missing option, key,
archive or notes, or notes that are empty).
EOF
}

usage_error() {
    printf 'error: %s\n' "$*" >&2
    printf 'Run scripts/make-appcast.sh --help for usage.\n' >&2
    exit 2
}
die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}
pass() { printf 'ok: %s\n' "$*"; }

need_value() {
    if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
        usage_error "$1 needs a value"
    fi
}

ARCHIVE=""
NOTES=""
TAG=""
OUT=""
PREVIOUS=""
REPOSITORY=""
PREFIX=""
LINK=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --archive)
            need_value "$@"
            ARCHIVE="$2"
            shift 2
            ;;
        --notes)
            need_value "$@"
            NOTES="$2"
            shift 2
            ;;
        --tag)
            need_value "$@"
            TAG="$2"
            shift 2
            ;;
        --out)
            need_value "$@"
            OUT="$2"
            shift 2
            ;;
        --previous)
            need_value "$@"
            PREVIOUS="$2"
            shift 2
            ;;
        --repository)
            need_value "$@"
            REPOSITORY="$2"
            shift 2
            ;;
        --download-url-prefix)
            need_value "$@"
            PREFIX="$2"
            shift 2
            ;;
        --link)
            need_value "$@"
            LINK="$2"
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) usage_error "unknown argument: $1" ;;
    esac
done
[[ -n "$ARCHIVE" ]] || usage_error "--archive is required"
[[ -n "$NOTES" ]] || usage_error "--notes is required"
[[ -n "$TAG" ]] || usage_error "--tag is required"
[[ -n "$OUT" ]] || usage_error "--out is required"

# The seed is base64. Whitespace around it (a trailing newline from a secret
# store) is not part of it. Nothing below ever prints it.
KEY="$(printf '%s' "${SPARKLE_ED_PRIVATE_KEY:-}" | tr -d '[:space:]')"
[[ -n "$KEY" ]] || usage_error "SPARKLE_ED_PRIVATE_KEY is not set"
case "$KEY" in
    *[!A-Za-z0-9+/=]*) usage_error "SPARKLE_ED_PRIVATE_KEY is not base64" ;;
esac
[[ -f "$ARCHIVE" ]] || usage_error "no such archive: $ARCHIVE"
[[ -s "$NOTES" ]] || usage_error "the release notes are missing or empty: $NOTES"
if [[ -n "$PREVIOUS" && ! -f "$PREVIOUS" ]]; then
    usage_error "no such appcast: $PREVIOUS"
fi
[[ -d "$(dirname "$OUT")" ]] || usage_error "the folder for $OUT does not exist"

if [[ "$TAG" != v* ]] || ! version_is_release "${TAG#v}"; then
    die "the tag must be a strict vX.Y.Z (no leading zeros, minor and patch at most 999): $TAG"
fi
VERSION="${TAG#v}"
BUILD="$(build_number_for "$VERSION")"
ARCHIVE_NAME="$(basename "$ARCHIVE")"
[[ "$ARCHIVE_NAME" == "RoomForMac-$VERSION.tar.xz" ]] ||
    die "the archive is named $ARCHIVE_NAME, but tag $TAG needs RoomForMac-$VERSION.tar.xz"

if [[ -z "$REPOSITORY" ]]; then
    REPOSITORY="$(distribution_value "$ROOT" RFM_REPOSITORY)"
fi
[[ "$REPOSITORY" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || usage_error "--repository must look like owner/name: $REPOSITORY"
if [[ -z "$PREFIX" ]]; then
    PREFIX="https://github.com/$REPOSITORY/releases/download/$TAG/"
fi
case "$PREFIX" in
    https://*/ | http://127.0.0.1/ | http://127.0.0.1:*/ | http://localhost/ | http://localhost:*/) ;;
    *) usage_error "--download-url-prefix must be an https URL ending in a slash (http only for 127.0.0.1 or localhost): $PREFIX" ;;
esac
if [[ -z "$LINK" ]]; then
    SITE_URL="$(distribution_value "$ROOT" RFM_SITE_URL)"
    LINK="$SITE_URL/"
fi

BIN=""
if [[ -z "${GENERATE_APPCAST:-}" || -z "${SIGN_UPDATE:-}" ]]; then
    BIN="${SPARKLE_BIN:-}"
    if [[ -z "$BIN" ]]; then
        BIN="$(sparkle_bin "$ROOT")"
    fi
fi
GENERATE_APPCAST="${GENERATE_APPCAST:-$BIN/generate_appcast}"
SIGN_UPDATE="${SIGN_UPDATE:-$BIN/sign_update}"
[[ -x "$GENERATE_APPCAST" ]] || die "generate_appcast not found or not executable: $GENERATE_APPCAST"
[[ -x "$SIGN_UPDATE" ]] || die "sign_update not found or not executable: $SIGN_UPDATE"

TEMP_ROOT="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "${TEMP_ROOT%/}/rfm-appcast.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# stdin to stdout, with every occurrence of the key replaced. The key travels in
# the environment, not in argv.
redact() {
    RFM_SECRET="$KEY" awk '
        BEGIN { secret = ENVIRON["RFM_SECRET"] }
        {
            line = $0
            out = ""
            while (secret != "" && (at = index(line, secret)) > 0) {
                out = out substr(line, 1, at - 1) "[key removed]"
                line = substr(line, at + length(secret))
            }
            print out line
        }
    '
}
# A tool's output, for the reader, on stderr.
show() { redact < "$1" >&2; }

# The <item>…</item> blocks of an appcast, one file each: DIR/item.1, item.2, …
# generate_appcast writes each tag on its own line, and so do the tests' stubs.
split_items() { # FILE DIR
    awk -v dir="$2" '
        /^[[:space:]]*<item>[[:space:]]*$/ { n++; inside = 1 }
        inside { print > (dir "/item." n) }
        /^[[:space:]]*<\/item>[[:space:]]*$/ { if (inside) close(dir "/item." n); inside = 0 }
    ' "$1"
}
# The text of the first <TAG>…</TAG> line of an item.
item_field() { # FILE TAG
    local text
    text="$(sed -n "s|^[[:space:]]*<$2>\\(.*\\)</$2>[[:space:]]*\$|\\1|p" "$1")"
    printf '%s\n' "${text%%$'\n'*}"
}
# The value of one attribute of the item's <enclosure …/> line.
enclosure_attr() { # FILE ATTRIBUTE
    local text
    text="$(sed -n "s|^.*<enclosure[^>]* $2=\"\\([^\"]*\\)\".*\$|\\1|p" "$1")"
    printf '%s\n' "${text%%$'\n'*}"
}
# The file in DIR whose sparkle:version is VERSION.
find_item() { # DIR VERSION
    local file
    for file in "$1"/item.*; do
        if [[ -f "$file" && "$(item_field "$file" sparkle:version)" == "$2" ]]; then
            printf '%s\n' "$file"
            return 0
        fi
    done
    return 1
}
count_items() { # DIR
    local file count=0
    for file in "$1"/item.*; do
        if [[ -f "$file" ]]; then
            count=$((count + 1))
        fi
    done
    printf '%s\n' "$count"
}

# split_items fails closed: if the file holds more sparkle:version lines than
# items were found, its layout is not the one this script reads.
check_split() { # FILE DIR
    local expected
    expected="$(grep -c '<sparkle:version>' "$1" || true)"
    [[ "$(count_items "$2")" -eq "$expected" ]] ||
        die "cannot read the items of $1: $expected sparkle:version lines, but $(count_items "$2") <item> blocks with each tag on its own line"
}

# Every earlier item's sparkle:version, newest first, with its file.
PREVIOUS_ITEMS="$WORK/previous-items"
NEW_ITEMS="$WORK/new-items"
mkdir "$PREVIOUS_ITEMS" "$NEW_ITEMS"
PREVIOUS_LIST="$WORK/previous-list"
: > "$PREVIOUS_LIST"
if [[ -n "$PREVIOUS" ]]; then
    grep -q '<rss' "$PREVIOUS" || die "$PREVIOUS is not an appcast"
    split_items "$PREVIOUS" "$PREVIOUS_ITEMS"
    check_split "$PREVIOUS" "$PREVIOUS_ITEMS"
    for file in "$PREVIOUS_ITEMS"/item.*; do
        [[ -f "$file" ]] || continue
        published="$(item_field "$file" sparkle:version)"
        [[ "$published" =~ ^[0-9]+$ ]] || die "$PREVIOUS has an item whose sparkle:version is not a number: ${published:-none}"
        if [[ "$published" -ge "$BUILD" ]]; then
            die "build $BUILD (tag $TAG) is not above build $published, which $PREVIOUS already publishes; Sparkle refuses downgrades, so a release needs a higher version"
        fi
        printf '%s %s\n' "$published" "$file" >> "$PREVIOUS_LIST"
    done
    sort -rn "$PREVIOUS_LIST" -o "$PREVIOUS_LIST"
    pass "build $BUILD is above all $(count_items "$PREVIOUS_ITEMS") published builds"
else
    pass "no earlier appcast: this is the first release"
fi

# Sparkle names an archive's release notes after the archive without its
# extension, which for a .tar.xz is either RoomForMac-X.Y.Z or RoomForMac-X.Y.Z.tar.
# Both spellings are staged; a copy that no archive matches is ignored.
STAGE="$WORK/stage"
mkdir "$STAGE"
cp "$ARCHIVE" "$STAGE/$ARCHIVE_NAME"
cp "$NOTES" "$STAGE/RoomForMac-$VERSION.md"
cp "$NOTES" "$STAGE/RoomForMac-$VERSION.tar.md"
if [[ -n "$PREVIOUS" ]]; then
    cp "$PREVIOUS" "$STAGE/appcast.xml"
fi

LOG="$WORK/tool.log"
if ! printf '%s' "$KEY" | "$GENERATE_APPCAST" --ed-key-file - \
    --download-url-prefix "$PREFIX" --link "$LINK" --embed-release-notes \
    --maximum-deltas 0 --maximum-versions "$MAXIMUM_VERSIONS" "$STAGE" > "$LOG" 2>&1; then
    show "$LOG"
    die "generate_appcast failed"
fi
if grep -q 'Skipped' "$LOG"; then
    show "$LOG"
    die "generate_appcast skipped an archive; the app inside $ARCHIVE_NAME failed its checks (a broken signature, nested code or version)"
fi
[[ -f "$STAGE/appcast.xml" ]] ||
    die "generate_appcast wrote no appcast.xml (the app's SUFeedURL must end in /appcast.xml)"
pass "generate_appcast accepted $ARCHIVE_NAME"

split_items "$STAGE/appcast.xml" "$NEW_ITEMS"
check_split "$STAGE/appcast.xml" "$NEW_ITEMS"
ITEM="$(find_item "$NEW_ITEMS" "$BUILD" || true)"
if [[ -z "$ITEM" ]]; then
    FOUND=""
    for file in "$NEW_ITEMS"/item.*; do
        if [[ -f "$file" ]]; then
            FOUND="$FOUND $(item_field "$file" sparkle:version)"
        fi
    done
    die "the new appcast has no item with sparkle:version $BUILD (found:${FOUND:- none}); the app inside the archive must carry CFBundleVersion $BUILD"
fi

ARCHIVE_BYTES="$(wc -c < "$ARCHIVE" | tr -d ' ')"
SIGNATURE="$(enclosure_attr "$ITEM" sparkle:edSignature)"
check_item() { # WHAT ACTUAL EXPECTED
    [[ "$2" == "$3" ]] || die "the new item's $1 is \"$2\", expected \"$3\""
}
check_item "sparkle:shortVersionString" "$(item_field "$ITEM" sparkle:shortVersionString)" "$VERSION"
check_item "enclosure url" "$(enclosure_attr "$ITEM" url)" "$PREFIX$ARCHIVE_NAME"
check_item "enclosure length" "$(enclosure_attr "$ITEM" length)" "$ARCHIVE_BYTES"
check_item "sparkle:minimumSystemVersion" "$(item_field "$ITEM" sparkle:minimumSystemVersion)" "$MINIMUM_MACOS"
# An Ed25519 signature is 64 bytes: 86 base64 characters and "==".
SIGNATURE_PATTERN='^[A-Za-z0-9+/]{86}==$'
[[ "$SIGNATURE" =~ $SIGNATURE_PATTERN ]] ||
    die "the new item has no usable sparkle:edSignature (got \"${SIGNATURE:-none}\")"
grep -q '<description' "$ITEM" || die "the new item embeds no release notes (no <description>)"
if grep -q 'sparkle:hardwareRequirements' "$STAGE/appcast.xml"; then
    die "the appcast carries sparkle:hardwareRequirements; RoomForMac ships a universal build, so no update may be limited to one architecture"
fi
pass "item $BUILD: version $VERSION, minimum macOS $MINIMUM_MACOS, $PREFIX$ARCHIVE_NAME ($ARCHIVE_BYTES bytes), signed, notes embedded"

# Earlier items: unchanged, and none of the newest KEEP_EARLIER missing.
RANK=0
while read -r published file; do
    RANK=$((RANK + 1))
    if now="$(find_item "$NEW_ITEMS" "$published")"; then
        cmp -s "$file" "$now" || die "earlier item $published changed in the new appcast; a release must leave earlier items byte for byte as they were"
    elif [[ "$RANK" -le "$KEEP_EARLIER" ]]; then
        die "earlier item $published is missing from the new appcast"
    fi
done < "$PREVIOUS_LIST"
if [[ -n "$PREVIOUS" ]]; then
    pass "earlier items are unchanged"
fi

VERIFY_LOG="$WORK/verify.log"
if ! printf '%s' "$KEY" | "$SIGN_UPDATE" --ed-key-file - --verify "$ARCHIVE" "$SIGNATURE" > "$VERIFY_LOG" 2>&1; then
    show "$VERIFY_LOG"
    die "sign_update does not verify $ARCHIVE_NAME against the signature in the new item"
fi
pass "sign_update verified $ARCHIVE_NAME against the item's signature"

cp "$STAGE/appcast.xml" "$OUT.partial"
mv -f "$OUT.partial" "$OUT"
pass "wrote $OUT, items: $(count_items "$NEW_ITEMS")"
