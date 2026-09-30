#!/bin/bash
# The release gate: checks a built RoomForMac.app before anything is packaged
# or published. It reads the app and runs nothing from it. Every check runs,
# even after one fails, and each prints one line:
#
#   ok: <check>
#   error: <check>: <detail>
#
# The checks, in order: strict signature verification; the signature (ad hoc,
# or the designated requirement); nested signers; hardened runtime; entitlements;
# no XPC services; Info.plist values; version; architectures.
#
# Both line kinds go to stdout, so a log keeps them in order. Usage errors go to
# stderr.
# The identifiers it pins are fixed for life (Global Constraints): the bundle
# ID, the designated requirement (DR), the feed URL, the public key and the
# build number scheme. Changing any of them strands installed copies.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/distribution.sh
source "$ROOT/scripts/lib/distribution.sh"
# shellcheck source=lib/version.sh
source "$ROOT/scripts/lib/version.sh"

BUNDLE_ID="com.roomformac.RoomForMac"
IDENTITY_SHA1_FILE="$ROOT/Config/signing-identity.sha1"
EXPECTED_ENTITLEMENTS=$'com.apple.security.automation.apple-events=true\ncom.apple.security.cs.disable-library-validation=true'
# Ruling 6: Info.plist carries only SUFeedURL, SUPublicEDKey and SUEnableAutomaticChecks.
FORBIDDEN_KEYS="SUEnableInstallerLauncherService SUEnableDownloaderService SUVerifyUpdateBeforeExtraction SURequireSignedFeed SUEnableSystemProfiling SUAutomaticallyUpdate SUScheduledCheckInterval"

# Every tool that reads a signature or a file's architectures is called through
# a variable, so the bats tests can put a stub there.
CODESIGN="${CODESIGN:-/usr/bin/codesign}"
PLUTIL="${PLUTIL:-/usr/bin/plutil}"
LIPO="${LIPO:-/usr/bin/lipo}"

# RFM_EXPECT_HARDENED=1 (the default): the app, its helpers, Autoupdate and
# Updater.app carry the runtime flag, and the app carries the two entitlements
# Ruling 5 needs. 0 pins the fallback instead: no flag anywhere and no
# entitlements. Task 4's spike changes this default to 0 if hardened runtime
# has to go.
EXPECT_HARDENED="${RFM_EXPECT_HARDENED:-1}"

usage() {
    cat << 'EOF'
Usage: scripts/check-release-app.sh <RoomForMac.app> [--adhoc] [--version X.Y.Z] [--no-universal]

Checks a built app before it is packaged. Prints one line per check, "ok: <check>"
or "error: <check>: <detail>", and runs every check.

  --adhoc          expect an ad-hoc signature (CI's app job); skips the designated
                   requirement, certificate and public-key checks
  --version X.Y.Z  also check CFBundleShortVersionString and CFBundleVersion
  --no-universal   do not require arm64 and x86_64 slices
  --help           show this help

Environment: RFM_EXPECT_HARDENED (1, the default, or 0; see the script).
Tools: CODESIGN, PLUTIL, LIPO.

Exit status: 0 every check passed; 1 a check failed; 2 usage error.
EOF
}

usage_error() {
    printf 'error: %s\n' "$*" >&2
    printf 'Run scripts/check-release-app.sh --help for usage.\n' >&2
    exit 2
}

APP=""
ADHOC=0
VERSION=""
VERSION_GIVEN=0
UNIVERSAL=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --adhoc)
            ADHOC=1
            shift
            ;;
        --no-universal)
            UNIVERSAL=0
            shift
            ;;
        --version)
            if [[ $# -lt 2 ]]; then
                usage_error "--version needs X.Y.Z"
            fi
            VERSION="$2"
            VERSION_GIVEN=1
            shift 2
            ;;
        --help | -h)
            usage
            exit 0
            ;;
        -*)
            usage_error "unknown option $1"
            ;;
        *)
            if [[ -n "$APP" ]]; then
                usage_error "more than one app: $APP and $1"
            fi
            APP="${1%/}"
            shift
            ;;
    esac
done
if [[ -z "$APP" ]]; then
    usage_error "no app given"
fi
if [[ ! -d "$APP/Contents" ]]; then
    usage_error "$APP is not an app bundle"
fi
if [[ "$VERSION_GIVEN" -eq 1 ]] && ! version_is_release "$VERSION"; then
    usage_error "--version needs a release version like 1.2.3, not \"$VERSION\""
fi
if [[ "$EXPECT_HARDENED" != 0 && "$EXPECT_HARDENED" != 1 ]]; then
    usage_error "RFM_EXPECT_HARDENED must be 0 or 1, not \"$EXPECT_HARDENED\""
fi

INFO_PLIST="$APP/Contents/Info.plist"
MAIN="$APP/Contents/MacOS/RoomForMac"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
SPARKLE_BINARY="$FRAMEWORK/Versions/B/Sparkle"
AUTOUPDATE="$FRAMEWORK/Versions/B/Autoupdate"
UPDATER_APP="$FRAMEWORK/Versions/B/Updater.app"

CHECKS=0
FAILURES=0

ok() {
    CHECKS=$((CHECKS + 1))
    printf 'ok: %s\n' "$1"
}
fail() {
    CHECKS=$((CHECKS + 1))
    FAILURES=$((FAILURES + 1))
    printf 'error: %s: %s\n' "$1" "$2"
}
# report NAME PROBLEMS: ok when PROBLEMS is empty, else a failure with the problems.
report() {
    if [[ -z "$2" ]]; then
        ok "$1"
    else
        fail "$1" "$2"
    fi
}
# add_problem TEXT: appends to the caller's $problems, separated by "; ".
# shellcheck disable=SC2154 # problems is the calling check's local
add_problem() {
    if [[ "; $problems; " == *"; $1; "* ]]; then
        return 0 # already reported
    fi
    if [[ -n "$problems" ]]; then
        problems="$problems; $1"
    else
        problems="$1"
    fi
}
rel() { printf '%s' "${1#"$APP"/}"; }
# oneline TEXT: the lines of TEXT joined by ", ", or "none".
oneline() {
    if [[ -z "$1" ]]; then
        printf 'none'
    else
        printf '%s' "$1" | tr '\n' ',' | sed -e 's/,$//' -e 's/,/, /g'
    fi
}

helper_paths() {
    local path
    for path in "$APP/Contents/Helpers"/*; do
        if [[ -e "$path" ]]; then
            printf '%s\n' "$path"
        fi
    done
    return 0
}

# The code that has a signature of its own and must match the app's.
signed_code_paths() {
    printf '%s\n' "$MAIN"
    helper_paths
    printf '%s\n' "$SPARKLE_BINARY" "$AUTOUPDATE" "$UPDATER_APP"
}

# "adhoc", or the certificate chain's Authority lines; fails when there is no signature.
signer_of() {
    local info
    info="$("$CODESIGN" --display --verbose=2 "$1" 2>&1)" || return 1
    if grep -qx 'Signature=adhoc' <<< "$info"; then
        printf 'adhoc\n'
    else
        grep '^Authority=' <<< "$info" | sed 's/^Authority=//'
    fi
}

# 0 when the runtime flag (0x10000) is in the signature's CodeDirectory flags,
# 1 when it is not, 2 when the flags cannot be read.
has_runtime_flag() {
    local info flags
    info="$("$CODESIGN" --display --verbose=2 "$1" 2>&1)" || return 2
    flags="$(sed -n 's/^CodeDirectory .* flags=\(0x[0-9a-fA-F]*\).*$/\1/p' <<< "$info" | sed -n '1p')"
    if [[ -z "$flags" ]]; then
        return 2
    fi
    if (((flags & 0x10000) != 0)); then
        return 0
    fi
    return 1
}

# The entitlements of PATH as sorted "key=value" lines; nothing when there are none.
entitlement_lines() {
    local xml
    xml="$("$CODESIGN" --display --entitlements - --xml "$1" 2> /dev/null)" || return 1
    if [[ -z "$xml" ]]; then
        return 0
    fi
    printf '%s' "$xml" | "$PLUTIL" -p - | sed -n 's/^ *"\(.*\)" => \(.*\)$/\1=\2/p' | LC_ALL=C sort
}

macho_files() {
    local file
    while IFS= read -r file; do
        if "$LIPO" -archs "$file" > /dev/null 2>&1; then
            printf '%s\n' "$file"
        fi
    done < <(find "$APP" -type f)
}

# The value of an Info.plist key, or failure when the key is missing.
plist_value() {
    "$PLUTIL" -extract "$1" raw -o - "$INFO_PLIST" 2> /dev/null
}

check_strict_verification() {
    local output
    if output="$("$CODESIGN" --verify --deep --strict "$APP" 2>&1)"; then
        ok "strict signature verification"
    else
        fail "strict signature verification" "$(printf '%s\n' "$output" | sed -n '1,2p' | tr '\n' ' ' | sed 's/ $//')"
    fi
}

check_signature() {
    local signer content sha expected found
    if [[ "$ADHOC" -eq 1 ]]; then
        if ! signer="$(signer_of "$APP")"; then
            fail "ad-hoc signature" "the app is not signed"
        elif [[ "$signer" != adhoc ]]; then
            fail "ad-hoc signature" "expected an ad-hoc signature, found $(oneline "$signer")"
        else
            ok "ad-hoc signature"
        fi
        return 0
    fi
    if [[ ! -f "$IDENTITY_SHA1_FILE" ]]; then
        fail "designated requirement" "Config/signing-identity.sha1 is missing (owner step A3 commits it)"
        return 0
    fi
    content="$(cat "$IDENTITY_SHA1_FILE")"
    if [[ ! "$content" =~ ^[0-9a-fA-F]{40}$ ]]; then
        fail "designated requirement" "Config/signing-identity.sha1 must hold exactly 40 hex digits"
        return 0
    fi
    sha="$(printf '%s' "$content" | tr 'A-F' 'a-f')"
    expected="identifier \"$BUNDLE_ID\" and certificate leaf = H\"$sha\""
    found="$("$CODESIGN" -d -r- "$APP" 2> /dev/null | sed -n -e 's/^# designated => //p' -e 's/^designated => //p')" || found=""
    if [[ "$found" == "$expected" ]]; then
        ok "designated requirement"
    else
        fail "designated requirement" "the app's is ${found:-none}, expected $expected"
    fi
}

check_nested_signers() {
    local problems="" app_signer path signer
    if ! app_signer="$(signer_of "$APP")"; then
        fail "nested signers" "the app is not signed"
        return 0
    fi
    if [[ -z "$(helper_paths)" ]]; then
        add_problem "Contents/Helpers holds no tools"
    fi
    while IFS= read -r path; do
        if [[ ! -e "$path" ]]; then
            add_problem "$(rel "$path") is missing"
        elif ! signer="$(signer_of "$path")"; then
            add_problem "$(rel "$path") is not signed"
        elif [[ "$signer" != "$app_signer" ]]; then
            add_problem "$(rel "$path") is signed by $(oneline "$signer"), the app by $(oneline "$app_signer")"
        fi
    done < <(signed_code_paths)
    report "nested signers" "$problems"
}

check_hardened_runtime() {
    local problems="" path status
    while IFS= read -r path; do
        if [[ ! -e "$path" ]]; then
            add_problem "$(rel "$path") is missing"
            continue
        fi
        if has_runtime_flag "$path"; then
            status=0
        else
            status=$?
        fi
        if [[ "$status" -eq 2 ]]; then
            add_problem "$(rel "$path") has no readable signature flags"
        elif [[ "$EXPECT_HARDENED" -eq 1 && "$status" -ne 0 ]]; then
            add_problem "$(rel "$path") lacks the runtime flag"
        elif [[ "$EXPECT_HARDENED" -eq 0 && "$status" -eq 0 ]]; then
            add_problem "$(rel "$path") carries the runtime flag, but RFM_EXPECT_HARDENED=0"
        fi
    done < <(
        printf '%s\n' "$APP"
        helper_paths
        printf '%s\n' "$AUTOUPDATE" "$UPDATER_APP"
    )
    report "hardened runtime" "$problems"
}

check_entitlements() {
    local problems="" expected="" lines path
    if [[ "$EXPECT_HARDENED" -eq 1 ]]; then
        expected="$EXPECTED_ENTITLEMENTS"
    fi
    if ! lines="$(entitlement_lines "$APP")"; then
        add_problem "the app's entitlements cannot be read"
    elif [[ "$lines" != "$expected" ]]; then
        add_problem "the app carries $(oneline "$lines"), expected $(oneline "$expected")"
    fi
    # The tools and Sparkle's updater code are signed without entitlements.
    while IFS= read -r path; do
        if [[ ! -e "$path" ]]; then
            continue # the signer check reports it
        fi
        if ! lines="$(entitlement_lines "$path")"; then
            add_problem "$(rel "$path")'s entitlements cannot be read"
        elif [[ -n "$lines" ]]; then
            add_problem "$(rel "$path") carries entitlements: $(oneline "$lines")"
        fi
    done < <(
        helper_paths
        printf '%s\n' "$AUTOUPDATE" "$UPDATER_APP"
    )
    # Nothing in the bundle may be debuggable, whatever else it carries.
    while IFS= read -r path; do
        if ! lines="$(entitlement_lines "$path")"; then
            add_problem "$(rel "$path")'s entitlements cannot be read"
        elif grep -q '^com.apple.security.get-task-allow=' <<< "$lines"; then
            add_problem "$(rel "$path") carries com.apple.security.get-task-allow"
        fi
    done < <(macho_files)
    report "entitlements" "$problems"
}

check_no_xpc_services() {
    local problems="" path
    if [[ ! -d "$FRAMEWORK" ]]; then
        fail "no XPC services" "Contents/Frameworks/Sparkle.framework is missing"
        return 0
    fi
    while IFS= read -r path; do
        add_problem "Sparkle.framework holds $(rel "$path")"
    done < <(find "$FRAMEWORK" \( -name XPCServices -o -name '*.xpc' \) | LC_ALL=C sort)
    report "no XPC services" "$problems"
}

# check_plist_value KEY EXPECTED
check_plist_value() {
    local key="$1" expected="$2" value
    if ! value="$(plist_value "$key")"; then
        fail "Info.plist $key" "is missing"
    elif [[ "$value" != "$expected" ]]; then
        fail "Info.plist $key" "is \"$value\", expected \"$expected\""
    else
        ok "Info.plist $key"
    fi
}

check_feed_url() {
    local expected value problems=""
    if ! expected="$(distribution_value "$ROOT" RFM_FEED_URL)"; then
        fail "Info.plist SUFeedURL" "cannot read RFM_FEED_URL from Config/Distribution.xcconfig"
        return 0
    fi
    if ! value="$(plist_value SUFeedURL)"; then
        fail "Info.plist SUFeedURL" "is missing"
        return 0
    fi
    if [[ "$value" != "$expected" ]]; then
        add_problem "is \"$value\", expected \"$expected\""
    fi
    if [[ "$value" != https://* ]]; then
        add_problem "is not an https URL"
    fi
    report "Info.plist SUFeedURL" "$problems"
}

check_public_key() {
    local expected value problems=""
    if [[ "$ADHOC" -eq 1 ]]; then
        ok "Info.plist SUPublicEDKey (skipped with --adhoc)"
        return 0
    fi
    if ! expected="$(distribution_value "$ROOT" RFM_SPARKLE_PUBLIC_KEY)"; then
        fail "Info.plist SUPublicEDKey" "cannot read RFM_SPARKLE_PUBLIC_KEY from Config/Distribution.xcconfig"
        return 0
    fi
    if [[ -z "$expected" ]]; then
        fail "Info.plist SUPublicEDKey" "RFM_SPARKLE_PUBLIC_KEY is empty in Config/Distribution.xcconfig (owner step A4)"
        return 0
    fi
    if ! value="$(plist_value SUPublicEDKey)" || [[ -z "$value" ]]; then
        fail "Info.plist SUPublicEDKey" "is missing or empty"
        return 0
    fi
    if [[ "$value" != "$expected" ]]; then
        add_problem "is \"$value\", expected the key in Config/Distribution.xcconfig"
    fi
    if [[ ! "$value" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
        add_problem "is not a 44-character base64 key"
    fi
    report "Info.plist SUPublicEDKey" "$problems"
}

check_forbidden_keys() {
    local problems="" key present=""
    if ! "$PLUTIL" -lint -s "$INFO_PLIST" > /dev/null 2>&1; then
        fail "Info.plist forbidden keys" "Contents/Info.plist cannot be read"
        return 0
    fi
    for key in $FORBIDDEN_KEYS; do
        if plist_value "$key" > /dev/null; then
            present="$present $key"
        fi
    done
    if [[ -n "$present" ]]; then
        add_problem "present:${present}"
    fi
    report "Info.plist forbidden keys" "$problems"
}

check_version() {
    local problems="" short build expected_build
    if [[ -z "$VERSION" ]]; then
        ok "version (not requested)"
        return 0
    fi
    expected_build="$(build_number_for "$VERSION")"
    short="$(plist_value CFBundleShortVersionString)" || short="missing"
    build="$(plist_value CFBundleVersion)" || build="missing"
    if [[ "$short" != "$VERSION" ]]; then
        add_problem "CFBundleShortVersionString is \"$short\", expected \"$VERSION\""
    fi
    if [[ "$build" != "$expected_build" ]]; then
        add_problem "CFBundleVersion is \"$build\", expected \"$expected_build\""
    fi
    report "version" "$problems"
}

check_architectures() {
    local problems="" path archs executable
    if [[ "$UNIVERSAL" -eq 0 ]]; then
        ok "architectures (skipped with --no-universal)"
        return 0
    fi
    executable="$("$PLUTIL" -extract CFBundleExecutable raw -o - "$UPDATER_APP/Contents/Info.plist" 2> /dev/null)" || executable=""
    while IFS= read -r path; do
        if [[ ! -e "$path" ]]; then
            add_problem "$(rel "$path") is missing"
        elif ! archs="$("$LIPO" -archs "$path" 2> /dev/null)"; then
            add_problem "$(rel "$path") is not a Mach-O file"
        elif [[ "$(tr ' ' '\n' <<< "$archs" | LC_ALL=C sort | tr '\n' ' ')" != "arm64 x86_64 " ]]; then
            add_problem "$(rel "$path") has $archs, expected x86_64 arm64"
        fi
    done < <(
        printf '%s\n' "$MAIN"
        helper_paths
        printf '%s\n' "$SPARKLE_BINARY" "$AUTOUPDATE"
        if [[ -n "$executable" ]]; then
            printf '%s\n' "$UPDATER_APP/Contents/MacOS/$executable"
        else
            printf '%s\n' "$UPDATER_APP/Contents/MacOS/Updater"
        fi
    )
    report "architectures" "$problems"
}

check_strict_verification
check_signature
check_nested_signers
check_hardened_runtime
check_entitlements
check_no_xpc_services
check_plist_value CFBundleIdentifier "$BUNDLE_ID"
check_feed_url
check_public_key
check_plist_value SUEnableAutomaticChecks true
check_plist_value RFMSkipQuarantineCleanup NO
check_forbidden_keys
check_plist_value LSMinimumSystemVersion 26.0
check_plist_value CFBundleIconName AppIcon
check_version
check_architectures

if [[ "$FAILURES" -gt 0 ]]; then
    printf 'release gate: %d of %d checks failed\n' "$FAILURES" "$CHECKS"
    exit 1
fi
printf 'release gate: %d checks passed\n' "$CHECKS"
