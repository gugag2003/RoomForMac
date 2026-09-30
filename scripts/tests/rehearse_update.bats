#!/usr/bin/env bats
# Checks scripts/rehearse-update.sh without Xcode, Sparkle, a keychain, hdiutil, a
# network or a real update. Each test runs a copy of the script inside a
# throwaway repository, with stub tools on XCODEGEN, XCODEBUILD, SWIFT, CODESIGN,
# SECURITY, MAKE_DMG, MAKE_UPDATE_ARCHIVE, MAKE_APPCAST and PYTHON3, and a stub
# sign_update in SPARKLE_BIN. The stubs log their arguments to $STATE. The stub
# xcodebuild "builds" a copy of one make_fake_app bundle (scripts/tests/fake_app.bash)
# with the version, feed, key and signer its build settings ask for, and the stub
# codesign reads that signer back from a marker file in the bundle. Tests never
# run a real build, signature, update check or Gatekeeper assessment, and never
# touch the real home, the keychain or /Applications. Needs clang, codesign, lipo and
# plutil, which make_fake_app needs too (any Mac with the command line tools).

load fake_app

setup_file() {
    # Skips the whole file, with a message, when clang, codesign, lipo or plutil is
    # missing. It must be called here: `skip` cannot work inside $(make_fake_app ...).
    fake_app_require_tools
    STUBS="$BATS_FILE_TMPDIR/stubs"
    mkdir -p "$STUBS/bin" "$STUBS/sparkle/bin"

    cat > "$STUBS/xcodegen" << 'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$STATE/xcodegen.log"
printf '%s\n' "$PWD" >> "$STATE/xcodegen.pwd"
STUB

    cat > "$STUBS/xcodebuild" << 'STUB'
#!/bin/bash
# xcodebuild(1) stand-in: logs its arguments, then "builds" a copy of the
# make_fake_app template with what the build settings ask for.
set -euo pipefail
printf '%s\n' "$*" >> "$STATE/xcodebuild.log"
printf '%s\n' "$PWD" >> "$STATE/xcodebuild.pwd"
if [[ "${STUB_XCODEBUILD_FAIL:-0}" == 1 ]]; then
    echo "error: stub build failure" >&2
    exit 65
fi
derived="" identity="" version="" build="" feed="" key="" skip=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -derivedDataPath)
            derived="$2"
            shift
            ;;
        CODE_SIGN_IDENTITY=*) identity="${1#*=}" ;;
        MARKETING_VERSION=*) version="${1#*=}" ;;
        CURRENT_PROJECT_VERSION=*) build="${1#*=}" ;;
        RFM_FEED_URL=*) feed="${1#*=}" ;;
        RFM_SPARKLE_PUBLIC_KEY=*) key="${1#*=}" ;;
        RFM_SKIP_QUARANTINE_CLEANUP=*) skip="${1#*=}" ;;
    esac
    shift
done
app="$derived/Build/Products/Release/RoomForMac.app"
rm -rf "$app"
mkdir -p "$(dirname "$app")"
cp -R "$TEMPLATE_APP" "$app"
plist="$app/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string com.roomformac.RoomForMac "$plist"
plutil -replace CFBundleShortVersionString -string "$version" "$plist"
plutil -replace CFBundleVersion -string "$build" "$plist"
plutil -replace SUFeedURL -string "$feed" "$plist"
plutil -replace SUPublicEDKey -string "$key" "$plist"
plutil -replace RFMSkipQuarantineCleanup -string "$skip" "$plist"
printf '%s\n' "$identity" > "$app/.stub-signer"
STUB

    cat > "$STUBS/codesign" << 'STUB'
#!/bin/bash
# codesign(1) stand-in. A bundle's "signature" is the name in its .stub-signer
# file, or - for ad hoc. --verify succeeds unless the bundle holds .stub-broken.
set -euo pipefail
printf '%s\n' "$*" >> "$STATE/codesign.log"
root_of() {
    local path="$1"
    while [[ "$path" != / && ! -f "$path/.stub-signer" ]]; do
        path="$(dirname "$path")"
    done
    printf '%s\n' "$path"
}
for last; do :; done
root="$(root_of "$last")"
case "$1" in
    --force)
        previous=""
        for argument; do
            if [[ "$previous" == --sign ]]; then
                printf '%s\n' "$argument" > "$root/.stub-signer"
            fi
            previous="$argument"
        done
        ;;
    --verify)
        [[ -f "$root/.stub-signer" && ! -f "$root/.stub-broken" ]]
        ;;
    -dvv)
        signer="$(cat "$root/.stub-signer")"
        echo "Executable=$last" >&2
        if [[ "$signer" == "-" ]]; then
            echo "Signature=adhoc" >&2
        else
            echo "Authority=$signer" >&2
        fi
        echo "TeamIdentifier=not set" >&2
        ;;
    -d)
        signer="$(cat "$root/.stub-signer")"
        if [[ "$signer" == "-" ]]; then
            echo '# designated => cdhash H"0123456789abcdef0123456789abcdef01234567"'
        else
            printf 'designated => identifier "com.roomformac.RoomForMac" and certificate leaf = H"%s"\n' \
                "$(printf '%s' "$signer" | shasum -a 1 | cut -c 1-40)"
        fi
        ;;
    *)
        echo "stub codesign: unexpected arguments: $*" >&2
        exit 64
        ;;
esac
STUB

    cat > "$STUBS/security" << 'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$STATE/security.log"
if [[ "$1" != find-identity ]]; then
    echo "stub security: unexpected command: $1" >&2
    exit 64
fi
echo "Policy: Code Signing"
echo "  Matching identities"
if [[ "${STUB_NO_IDENTITY:-0}" == 1 ]]; then
    echo "     0 identities found"
else
    printf '  1) 1A2B3C4D5E6F708192A3B4C5D6E7F8091A2B3C4D "%s" (CSSMERR_TP_NOT_TRUSTED)\n' \
        "${STUB_IDENTITY:-RoomForMac Self-Signed}"
    echo "     1 identities found"
fi
STUB

    cat > "$STUBS/swift" << 'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$STATE/swift.log"
printf '%s %s\n' "$STUB_SEED" "$STUB_PUBLIC"
STUB

    cat > "$STUBS/make-update-archive" << 'STUB'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$STATE/archive.log"
COPYFILE_DISABLE=1 tar --no-xattrs -cJf "$2" -C "$(dirname "$1")" "$(basename "$1")"
printf '%s %s %s\n' "$2" "$(stat -f %z "$2")" "$(shasum -a 256 < "$2" | cut -c 1-64)"
STUB

    cat > "$STUBS/make-appcast" << 'STUB'
#!/bin/bash
# make-appcast.sh stand-in: writes a one-item appcast (plus the previous feed's
# items, unless STUB_APPCAST_DROP_OLD=1). The "signature" of an archive is the
# SHA-256 of its bytes, which the stub sign_update recomputes.
set -euo pipefail
printf '%s\n' "$*" >> "$STATE/appcast.log"
if [[ -z "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
    echo "stub make-appcast: SPARKLE_ED_PRIVATE_KEY is not set" >&2
    exit 2
fi
printf 'seed-in-env %s\n' "${#SPARKLE_ED_PRIVATE_KEY}" >> "$STATE/appcast.env"
archive="" tag="" out="" previous="" prefix=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --archive) archive="$2" ;;
        --tag) tag="$2" ;;
        --out) out="$2" ;;
        --previous) previous="$2" ;;
        --download-url-prefix) prefix="$2" ;;
    esac
    shift
done
version="${tag#v}"
IFS=. read -r major minor patch <<< "$version"
build=$((major * 1000000 + minor * 1000 + patch))
{
    echo '<?xml version="1.0" encoding="utf-8"?>'
    echo '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
    echo '  <channel>'
    echo '    <title>RoomForMac</title>'
    echo '    <item>'
    echo "      <title>$version</title>"
    echo "      <sparkle:version>$build</sparkle:version>"
    echo "      <sparkle:shortVersionString>$version</sparkle:shortVersionString>"
    echo '      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>'
    printf '      <enclosure url="%s%s" length="%s" type="application/octet-stream" sparkle:edSignature="%s"/>\n' \
        "$prefix" "$(basename "$archive")" "$(stat -f %z "$archive")" "$(shasum -a 256 < "$archive" | cut -c 1-64)"
    echo '    </item>'
    if [[ -n "$previous" && "${STUB_APPCAST_DROP_OLD:-0}" != 1 ]]; then
        sed -n '/<item>/,/<\/item>/p' "$previous"
    fi
    echo '  </channel>'
    echo '</rss>'
} > "$out"
STUB

    cat > "$STUBS/sparkle/bin/sign_update" << 'STUB'
#!/bin/bash
# sign_update stand-in: `--ed-key-file - --verify ARCHIVE SIGNATURE` with a key on stdin.
printf '%s\n' "$*" >> "$STATE/sign_update.log"
if [[ "${STUB_SIGN_UPDATE_ACCEPT_ALL:-0}" == 1 ]]; then
    cat > /dev/null
    exit 0
fi
if [[ "$1" != --ed-key-file || "$2" != - || "$3" != --verify ]]; then
    echo "stub sign_update: unexpected arguments: $*" >&2
    exit 64
fi
if [[ -z "$(cat)" ]]; then
    echo "stub sign_update: no key on stdin" >&2
    exit 2
fi
[[ "$5" == "$(shasum -a 256 < "$4" | cut -c 1-64)" ]]
STUB

    cat > "$STUBS/make-dmg" << 'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$STATE/dmg.log"
printf 'DMG of %s\n' "$1" > "$2"
printf '%s 10 0000\n' "$2"
STUB

    cat > "$STUBS/python3" << 'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$STATE/python3.log"
STUB

    # The script must never install, launch or quit an app.
    for tool in open osascript killall pkill launchctl; do
        cat > "$STUBS/bin/$tool" << 'SPY'
#!/bin/bash
printf '%s %s\n' "$(basename "$0")" "$*" >> "$STATE/spy.log"
exit 1
SPY
        chmod +x "$STUBS/bin/$tool"
    done

    chmod +x "$STUBS/xcodegen" "$STUBS/xcodebuild" "$STUBS/codesign" "$STUBS/security" "$STUBS/swift" \
        "$STUBS/make-update-archive" "$STUBS/make-appcast" "$STUBS/sparkle/bin/sign_update" \
        "$STUBS/make-dmg" "$STUBS/python3"

    # 44 base64 characters each, like a 32-byte key.
    STUB_SEED="SEEDSEEDSEEDSEEDSEEDSEEDSEEDSEEDSEEDSEEDSEE="
    STUB_PUBLIC="PUBLICPUBLICPUBLICPUBLICPUBLICPUBLICPUBLICP="
    TEMPLATE_APP="$(make_fake_app "$BATS_FILE_TMPDIR/template")"
    [ -d "$TEMPLATE_APP/Contents/Frameworks/Sparkle.framework" ]
    export STUBS STUB_SEED STUB_PUBLIC TEMPLATE_APP
}

setup() {
    TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
    REPO="$TMP/repo"
    STATE="$TMP/state"
    HOME="$TMP/home"
    TMPDIR="$TMP/tmp"
    mkdir -p "$REPO/scripts/lib" "$REPO/Config" "$REPO/build" "$STATE" "$HOME" "$TMPDIR"
    cp "$BATS_TEST_DIRNAME/../rehearse-update.sh" "$REPO/scripts/"
    cp "$BATS_TEST_DIRNAME/../lib/version.sh" "$REPO/scripts/lib/"
    cp "$BATS_TEST_DIRNAME/../lib/sparkle.sh" "$REPO/scripts/lib/"
    : > "$REPO/scripts/lib/ed25519-keypair.swift"
    printf 'RFM_FEED_URL = https:/$()/example.invalid/appcast.xml\n' > "$REPO/Config/Distribution.xcconfig"
    SCRIPT="$REPO/scripts/rehearse-update.sh"
    WORK="$REPO/build/rehearsal"
    unset SIGN_UPDATE PYTHON3 RFM_REHEARSAL_DERIVED_DATA STUB_NO_IDENTITY STUB_IDENTITY \
        STUB_XCODEBUILD_FAIL STUB_APPCAST_DROP_OLD STUB_SIGN_UPDATE_ACCEPT_ALL
    PATH="$STUBS/bin:$PATH"
    XCODEGEN="$STUBS/xcodegen"
    XCODEBUILD="$STUBS/xcodebuild"
    SWIFT="$STUBS/swift"
    CODESIGN="$STUBS/codesign"
    SECURITY="$STUBS/security"
    MAKE_DMG="$STUBS/make-dmg"
    MAKE_UPDATE_ARCHIVE="$STUBS/make-update-archive"
    MAKE_APPCAST="$STUBS/make-appcast"
    SPARKLE_BIN="$STUBS/sparkle/bin"
    export HOME TMPDIR STATE PATH XCODEGEN XCODEBUILD SWIFT CODESIGN SECURITY MAKE_DMG \
        MAKE_UPDATE_ARCHIVE MAKE_APPCAST SPARKLE_BIN
}

# Runs prepare against the stubs; leaves its output in $output.
prepare_fixture() {
    run "$SCRIPT" prepare "$WORK"
    if [ "$status" -ne 0 ]; then
        echo "$output" >&2
        return 1
    fi
}

# A minimal prepared folder, for the tests that do not need a whole prepare.
make_prepared_stub() {
    mkdir -p "$WORK/feed" "$WORK/feed-bad"
    printf 'IDENTITY=RoomForMac Self-Signed\nPORT=9911\nSPARKLE_BIN=%s\n' "$SPARKLE_BIN" > "$WORK/rehearsal.env"
}

@test "--help prints the usage of all three commands and exits 0" {
    run "$SCRIPT" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: scripts/rehearse-update.sh prepare <workdir> [--identity NAME] [--keychain PATH] [--port N]"* ]] || return 1
    [[ "$output" == *"scripts/rehearse-update.sh check <workdir>"* ]] || return 1
    [[ "$output" == *"scripts/rehearse-update.sh serve <workdir> [--bad] [--port N]"* ]] || return 1
    [ ! -e "$STATE/xcodebuild.log" ]
}

@test "no command and an unknown command are usage errors" {
    run "$SCRIPT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: missing command: prepare, check or serve"* ]] || return 1
    run "$SCRIPT" rehearse
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: unknown command: rehearse"* ]]
}

@test "prepare refuses a missing workdir, a missing value, a bad port, identity or keychain before it builds" {
    local port
    run "$SCRIPT" prepare
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: prepare needs a <workdir>"* ]] || return 1
    run "$SCRIPT" prepare "$WORK" --port
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: --port needs a value"* ]] || return 1
    for port in abc 80 1023 65536 8765x; do
        run "$SCRIPT" prepare "$WORK" --port "$port"
        [ "$status" -eq 2 ]
        [[ "$output" == *"error: --port must be a number from 1024 to 65535"* ]] || return 1
    done
    run "$SCRIPT" prepare "$WORK" --identity 'Bad "Name"'
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: --identity may contain only"* ]] || return 1
    run "$SCRIPT" prepare "$WORK" --keychain "$TMP/missing.keychain-db"
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: keychain not found"* ]] || return 1
    run "$SCRIPT" prepare "$WORK" --frobnicate
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: unknown argument: --frobnicate"* ]] || return 1
    [ ! -e "$WORK" ]
    [ ! -e "$STATE/xcodebuild.log" ]
    [ ! -e "$STATE/security.log" ]
}

@test "a workdir outside build/ and TMPDIR is refused before anything is created" {
    run "$SCRIPT" prepare "$TMP/elsewhere/rehearsal"
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: <workdir> must be under $REPO/build or under \$TMPDIR"* ]] || return 1
    [ ! -e "$TMP/elsewhere" ]
    [ ! -e "$STATE/security.log" ]
    [ ! -e "$STATE/xcodebuild.log" ]
    # Under TMPDIR is allowed: the same command works there.
    run "$SCRIPT" prepare "$TMPDIR/rehearsal"
    [ "$status" -eq 0 ]
    [ -f "$TMPDIR/rehearsal/CHECKLIST.md" ]
}

@test "a workdir that already holds something is refused and left alone" {
    mkdir -p "$WORK"
    printf 'keep\n' > "$WORK/notes.txt"
    run "$SCRIPT" prepare "$WORK"
    [ "$status" -eq 2 ]
    [[ "$output" == *"is not empty; remove it first"* ]] || return 1
    [ "$(cat "$WORK/notes.txt")" = "keep" ]
    [ ! -e "$STATE/xcodebuild.log" ]
}

@test "prepare stops before building when the identity is not in the keychain" {
    run env STUB_NO_IDENTITY=1 "$SCRIPT" prepare "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *'error: no code-signing identity named "RoomForMac Self-Signed"'* ]] || return 1
    [ ! -e "$WORK" ]
    [ ! -e "$STATE/xcodebuild.log" ]
}

@test "prepare makes the builds, images, feeds, keys and checklist, and warns about nothing" {
    local path
    prepare_fixture
    for path in build1/RoomForMac.app build1-nocleanup/RoomForMac.app build2/RoomForMac.app \
        dmg/RoomForMac-0.0.1.dmg dmg-nocleanup/RoomForMac-0.0.1.dmg \
        feed/appcast.xml feed/RoomForMac-0.0.2.tar.xz feed/RoomForMac-0.0.2.md \
        feed-bad/appcast.xml feed-bad/RoomForMac-0.0.2.tar.xz keys/seed keys/public CHECKLIST.md rehearsal.env; do
        [ -e "$WORK/$path" ] || {
            echo "missing $path" >&2
            return 1
        }
    done
    [[ "$output" != *"warning:"* ]] || return 1
    [ "$(ls "$WORK/feed" | LC_ALL=C sort | tr '\n' ' ')" = "RoomForMac-0.0.2.md RoomForMac-0.0.2.tar.xz appcast.xml " ]
    [ "$(ls "$WORK/feed-bad" | LC_ALL=C sort | tr '\n' ' ')" = "RoomForMac-0.0.2.tar.xz appcast.xml " ]
    [ ! -e "$WORK/bad-src" ]
    [ "$(stat -f %Lp "$WORK/keys")" = 700 ]
    [ "$(stat -f %Lp "$WORK/keys/seed")" = 600 ]
    [ "$(stat -f %Lp "$WORK/keys/public")" = 600 ]
    [ "$(cat "$WORK/keys/seed")" = "$STUB_SEED" ]
    [ "$(cat "$WORK/keys/public")" = "$STUB_PUBLIC" ]
}

@test "prepare builds three Release apps through the project, overriding only the feed, key, versions and signing" {
    local common feed
    prepare_fixture
    [ "$(wc -l < "$STATE/xcodebuild.log" | tr -d ' ')" = 3 ]
    common="-project RoomForMac.xcodeproj -scheme RoomForMac -configuration Release -destination generic/platform=macOS -derivedDataPath $WORK/dd CODE_SIGN_IDENTITY=RoomForMac Self-Signed"
    feed="RFM_FEED_URL=http://127.0.0.1:8765/appcast.xml RFM_SPARKLE_PUBLIC_KEY=$STUB_PUBLIC"
    [ "$(sed -n 1p "$STATE/xcodebuild.log")" = "$common MARKETING_VERSION=0.0.1 CURRENT_PROJECT_VERSION=1 $feed RFM_SKIP_QUARANTINE_CLEANUP=NO build" ]
    [ "$(sed -n 2p "$STATE/xcodebuild.log")" = "$common MARKETING_VERSION=0.0.1 CURRENT_PROJECT_VERSION=1 $feed RFM_SKIP_QUARANTINE_CLEANUP=YES build" ]
    [ "$(sed -n 3p "$STATE/xcodebuild.log")" = "$common MARKETING_VERSION=0.0.2 CURRENT_PROJECT_VERSION=2 $feed RFM_SKIP_QUARANTINE_CLEANUP=NO build" ]
    [[ "$(cat "$STATE/xcodebuild.log")" != *OTHER_CODE_SIGN_FLAGS* ]] || return 1
    # From the repository root, and never by editing the xcconfig.
    [ "$(sort -u "$STATE/xcodebuild.pwd")" = "$REPO" ]
    [ "$(cat "$STATE/xcodegen.log")" = "generate" ]
    [ "$(cat "$STATE/xcodegen.pwd")" = "$REPO" ]
    [ "$(cat "$REPO/Config/Distribution.xcconfig")" = 'RFM_FEED_URL = https:/$()/example.invalid/appcast.xml' ]
}

@test "--identity, --keychain and --port reach the identity check, the build, the feed URL and the checklist" {
    local line
    : > "$TMP/rehearsal.keychain-db"
    run env STUB_IDENTITY="RoomForMac Rehearsal" "$SCRIPT" prepare "$WORK" \
        --identity "RoomForMac Rehearsal" --keychain "$TMP/rehearsal.keychain-db" --port 9911
    [ "$status" -eq 0 ]
    [ "$(cat "$STATE/security.log")" = "find-identity -p codesigning $TMP/rehearsal.keychain-db" ]
    line="$(sed -n 1p "$STATE/xcodebuild.log")"
    [[ "$line" == *"CODE_SIGN_IDENTITY=RoomForMac Rehearsal OTHER_CODE_SIGN_FLAGS=--keychain $TMP/rehearsal.keychain-db MARKETING_VERSION=0.0.1"* ]] || return 1
    [[ "$line" == *"RFM_FEED_URL=http://127.0.0.1:9911/appcast.xml"* ]] || return 1
    grep -qx 'PORT=9911' "$WORK/rehearsal.env"
    grep -qx 'IDENTITY=RoomForMac Rehearsal' "$WORK/rehearsal.env"
    grep -qx "KEYCHAIN=$TMP/rehearsal.keychain-db" "$WORK/rehearsal.env"
    grep -qF 'http://127.0.0.1:9911/RoomForMac-0.0.2.tar.xz' "$WORK/feed/appcast.xml"
    grep -qF "OTHER_CODE_SIGN_FLAGS=\"--keychain $TMP/rehearsal.keychain-db\" \\" "$WORK/CHECKLIST.md"
    grep -qF 'RFM_FEED_URL="http://127.0.0.1:9911/appcast.xml"' "$WORK/CHECKLIST.md"
}

@test "a failed build stops prepare with the log's tail, and the folder is not marked prepared" {
    run env STUB_XCODEBUILD_FAIL=1 "$SCRIPT" prepare "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"stub build failure"* ]] || return 1
    [[ "$output" == *"error: the 0.0.1 build failed; the full output is in $WORK/logs/build1.log"* ]] || return 1
    [ ! -e "$WORK/rehearsal.env" ]
    [ ! -e "$WORK/CHECKLIST.md" ]
    run "$SCRIPT" check "$WORK"
    [ "$status" -eq 2 ]
    [[ "$output" == *"is not a prepared rehearsal folder"* ]]
}

@test "prepare makes the images, archives and appcasts through the release scripts" {
    prepare_fixture
    [ "$(sed -n 1p "$STATE/dmg.log")" = "$WORK/build1/RoomForMac.app $WORK/dmg/RoomForMac-0.0.1.dmg" ]
    [ "$(sed -n 2p "$STATE/dmg.log")" = "$WORK/build1-nocleanup/RoomForMac.app $WORK/dmg-nocleanup/RoomForMac-0.0.1.dmg" ]
    [ "$(sed -n 1p "$STATE/archive.log")" = "$WORK/build2/RoomForMac.app $WORK/feed/RoomForMac-0.0.2.tar.xz" ]
    [ "$(sed -n 2p "$STATE/archive.log")" = "$WORK/bad-src/app/RoomForMac.app $WORK/bad-src/out/RoomForMac-0.0.2.tar.xz" ]
    [ "$(sed -n 1p "$STATE/appcast.log")" = "--archive $WORK/feed/RoomForMac-0.0.2.tar.xz --notes $WORK/feed/RoomForMac-0.0.2.md --tag v0.0.2 --out $WORK/feed/appcast.xml --download-url-prefix http://127.0.0.1:8765/ --link http://127.0.0.1:8765/" ]
    [ "$(sed -n 2p "$STATE/appcast.log")" = "--archive $WORK/bad-src/out/RoomForMac-0.0.2.tar.xz --notes $WORK/feed/RoomForMac-0.0.2.md --tag v0.0.2 --out $WORK/bad-src/out/appcast.xml --download-url-prefix http://127.0.0.1:8765/ --link http://127.0.0.1:8765/" ]
    grep -qx -- "--force --deep --sign - --timestamp=none --options runtime $WORK/bad-src/app/RoomForMac.app" "$STATE/codesign.log"
}

@test "the broken feed is the valid one with an ad-hoc signed archive and a corrupted signature" {
    local good_sig bad_sig expected
    prepare_fixture
    bad_sig="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$WORK/feed-bad/appcast.xml")"
    expected="$(shasum -a 256 < "$WORK/feed-bad/RoomForMac-0.0.2.tar.xz" | cut -c 1-64)"
    good_sig="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$WORK/feed/appcast.xml")"
    [ "${#bad_sig}" -eq "${#expected}" ]
    [ "${bad_sig:1}" = "${expected:1}" ]
    [ "${bad_sig:0:1}" != "${expected:0:1}" ]
    [ "$good_sig" = "$(shasum -a 256 < "$WORK/feed/RoomForMac-0.0.2.tar.xz" | cut -c 1-64)" ]
    [ "$(tar -xOf "$WORK/feed/RoomForMac-0.0.2.tar.xz" RoomForMac.app/.stub-signer)" = "RoomForMac Self-Signed" ]
    [ "$(tar -xOf "$WORK/feed-bad/RoomForMac-0.0.2.tar.xz" RoomForMac.app/.stub-signer)" = "-" ]
}

@test "the throwaway seed reaches make-appcast only through its environment and is never printed" {
    prepare_fixture
    [[ "$output" != *"$STUB_SEED"* ]] || return 1
    [ "$(sort -u "$STATE/appcast.env")" = "seed-in-env 44" ]
    run grep -rF "$STUB_SEED" "$STATE"
    [ "$status" -eq 1 ]
}

@test "prepare never installs, launches or quits an app and never touches Applications" {
    prepare_fixture
    [ ! -e "$STATE/spy.log" ]
    [ ! -e "$HOME/Applications" ]
    run grep -rl "/Applications" "$STATE"
    [ "$status" -eq 1 ]
}

@test "RFM_REHEARSAL_DERIVED_DATA moves the build, and a folder under Desktop draws a warning" {
    run env RFM_REHEARSAL_DERIVED_DATA="$HOME/Desktop/dd" "$SCRIPT" prepare "$WORK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"warning: DerivedData $HOME/Desktop/dd is under ~/Desktop"* ]] || return 1
    [[ "$(sed -n 1p "$STATE/xcodebuild.log")" == *"-derivedDataPath $HOME/Desktop/dd "* ]] || return 1
    [ ! -e "$WORK/dd" ]
    grep -qx "DERIVED_DATA=$HOME/Desktop/dd" "$WORK/rehearsal.env"
}

@test "CHECKLIST.md has V1 to V10, this folder's commands and no unreplaced placeholder" {
    local n
    prepare_fixture
    for n in 1 2 3 4 5 6 7 8 9 10; do
        grep -qE "^## V$n\. " "$WORK/CHECKLIST.md" || {
            echo "no V$n heading" >&2
            return 1
        }
    done
    grep -qF "scripts/rehearse-update.sh serve \"$WORK\" --bad" "$WORK/CHECKLIST.md"
    grep -qF "ditto \"$WORK/build1/RoomForMac.app\" ~/Applications/RoomForMac.app" "$WORK/CHECKLIST.md"
    grep -qF 'xattr -dr com.apple.quarantine ~/Applications/RoomForMac.app' "$WORK/CHECKLIST.md"
    grep -qF -- "--directory \"$WORK/dmg-nocleanup\"" "$WORK/CHECKLIST.md"
    grep -qF 'process == "syspolicyd"' "$WORK/CHECKLIST.md"
    grep -qF 'MARKETING_VERSION=0.0.3 CURRENT_PROJECT_VERSION=3' "$WORK/CHECKLIST.md"
    grep -qF 'RFM_FEED_URL="http://127.0.0.1:8765/appcast.xml"' "$WORK/CHECKLIST.md"
    grep -qF -- '-RFMUITestScenario onboarded' "$WORK/CHECKLIST.md"
    run grep -E '@[A-Z0-9_]+@' "$WORK/CHECKLIST.md"
    [ "$status" -eq 1 ]
}

@test "check passes on a prepared rehearsal and never shows the seed" {
    prepare_fixture
    run "$SCRIPT" check "$WORK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok: V1 build1: Sparkle.framework has no XPC services"* ]] || return 1
    [[ "$output" == *'ok: V1 build2: the app, Autoupdate, Updater.app and Sparkle.framework are signed by "RoomForMac Self-Signed"'* ]] || return 1
    [[ "$output" == *"ok: V1 build2: strict deep verification passes"* ]] || return 1
    [[ "$output" == *"ok: V1 build1-nocleanup: Info.plist says 0.0.1 (1), the rehearsal feed and key, RFMSkipQuarantineCleanup YES"* ]] || return 1
    [[ "$output" == *"ok: V1: build1, build2 and build1-nocleanup share one designated requirement"* ]] || return 1
    [[ "$output" == *"ok: V2 feed: one item, build 2 (0.0.2), minimumSystemVersion 26.0"* ]] || return 1
    [[ "$output" == *"ok: V2 feed: sign_update --verify accepts the archive's edSignature"* ]] || return 1
    [[ "$output" == *"ok: V4 feed-bad: sign_update --verify rejects the corrupted edSignature"* ]] || return 1
    [[ "$output" == *"ok: V4 feed-bad: its archive holds an ad-hoc signed app"* ]] || return 1
    [[ "$output" == *"ok: V9: the second feed has two items"* ]] || return 1
    [[ "$output" == *"ok: V9: the 0.0.1 item is byte-identical in the second feed"* ]] || return 1
    [[ "$output" != *"error:"* ]] || return 1
    [[ "$output" != *"$STUB_SEED"* ]] || return 1
    [[ "$output" == *"==> all 22 checks passed"* ]] || return 1
    run grep -rF "$STUB_SEED" "$STATE"
    [ "$status" -eq 1 ]
}

@test "check asks sign_update to verify with the key on stdin, never in argv" {
    prepare_fixture
    run "$SCRIPT" check "$WORK"
    [ "$status" -eq 0 ]
    # One call for V2's good signature and two for V4's corrupted one.
    [ "$(wc -l < "$STATE/sign_update.log" | tr -d ' ')" = 3 ]
    [ "$(grep -c '^--ed-key-file - --verify /' "$STATE/sign_update.log")" = 3 ]
    run grep -F "$STUB_SEED" "$STATE/sign_update.log"
    [ "$status" -eq 1 ]
}

@test "check fails when Sparkle.framework still has XPC services, and still runs every other check" {
    prepare_fixture
    mkdir -p "$WORK/build1/RoomForMac.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc"
    run "$SCRIPT" check "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"error: V1 build1: Sparkle.framework still has XPC services, for example "* ]] || return 1
    [[ "$output" == *"ok: V1 build2: Sparkle.framework has no XPC services"* ]] || return 1
    [[ "$output" == *"ok: V9: the 0.0.1 item is byte-identical in the second feed"* ]] || return 1
    [[ "$output" == *"error: 1 of 22 checks failed"* ]]
}

@test "check fails when sign_update accepts the corrupted signature" {
    prepare_fixture
    run env STUB_SIGN_UPDATE_ACCEPT_ALL=1 "$SCRIPT" check "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"error: V4 feed-bad: sign_update --verify accepts the corrupted edSignature"* ]] || return 1
    [[ "$output" == *"ok: V2 feed: sign_update --verify accepts the archive's edSignature"* ]]
}

@test "check fails when sign_update rejects the good signature, and then does not trust V4" {
    prepare_fixture
    printf 'XXXX' >> "$WORK/feed/RoomForMac-0.0.2.tar.xz"
    run "$SCRIPT" check "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"error: V2 feed: the item is wrong in: length("* ]] || return 1
    [[ "$output" == *"error: V2 feed: sign_update --verify rejects the archive's edSignature"* ]] || return 1
    [[ "$output" == *"error: V4 feed-bad: not run, because V2's sign_update --verify did not pass"* ]]
}

@test "check fails when the broken feed's archive is signed by the app's own certificate" {
    prepare_fixture
    cp "$WORK/feed/RoomForMac-0.0.2.tar.xz" "$WORK/feed-bad/RoomForMac-0.0.2.tar.xz"
    run "$SCRIPT" check "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"ok: V4 feed-bad: sign_update --verify rejects the corrupted edSignature"* ]] || return 1
    [[ "$output" == *"error: V4 feed-bad: its archive does not hold an ad-hoc signed RoomForMac.app"* ]]
}

@test "check fails when a build is signed by another identity" {
    prepare_fixture
    printf 'Someone Else\n' > "$WORK/build2/RoomForMac.app/.stub-signer"
    run "$SCRIPT" check "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *'error: V1 build2: not signed by "RoomForMac Self-Signed": RoomForMac.app'* ]] || return 1
    [[ "$output" == *"error: V1: the three builds do not share one designated requirement"* ]]
}

@test "check fails when a build does not verify strictly" {
    prepare_fixture
    : > "$WORK/build1/RoomForMac.app/.stub-broken"
    run "$SCRIPT" check "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"error: V1 build1: codesign --verify --deep --strict fails"* ]]
}

@test "check fails when the appcast item carries a hardware requirement" {
    prepare_fixture
    sed 's#</item>#<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements></item>#' \
        "$WORK/feed/appcast.xml" > "$TMP/appcast.xml"
    cp "$TMP/appcast.xml" "$WORK/feed/appcast.xml"
    run "$SCRIPT" check "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"error: V2 feed: the item is wrong in: hardwareRequirements(1)"* ]]
}

@test "check fails when the appcast item's minimum system version is not 26.0" {
    prepare_fixture
    sed 's#>26.0<#>15.0<#' "$WORK/feed/appcast.xml" > "$TMP/appcast.xml"
    cp "$TMP/appcast.xml" "$WORK/feed/appcast.xml"
    run "$SCRIPT" check "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"error: V2 feed: the item is wrong in: minimumSystemVersion(15.0)"* ]]
}

@test "check fails when a build carries another feed URL, and when the two V6 builds are swapped" {
    prepare_fixture
    plutil -replace SUFeedURL -string https://example.invalid/appcast.xml "$WORK/build2/RoomForMac.app/Contents/Info.plist"
    plutil -replace RFMSkipQuarantineCleanup -string NO "$WORK/build1-nocleanup/RoomForMac.app/Contents/Info.plist"
    run "$SCRIPT" check "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"error: V1 build2: Info.plist differs from what prepare set in: SUFeedURL"* ]] || return 1
    [[ "$output" == *"error: V1 build1-nocleanup: Info.plist differs from what prepare set in: RFMSkipQuarantineCleanup"* ]]
}

@test "check fails when the second release drops the first item" {
    prepare_fixture
    run env STUB_APPCAST_DROP_OLD=1 "$SCRIPT" check "$WORK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"error: V9: the second feed should have two items"* ]] || return 1
    [[ "$output" == *"error: V9: the 0.0.1 item changed, or is missing, in the second feed"* ]]
}

@test "check without a workdir is a usage error" {
    run "$SCRIPT" check
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: check needs a <workdir>"* ]]
}

@test "serve serves the valid feed on 127.0.0.1 at the port the builds were made for" {
    make_prepared_stub
    run env PYTHON3="$STUBS/python3" "$SCRIPT" serve "$WORK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"serving $WORK/feed on http://127.0.0.1:9911/"* ]] || return 1
    [ "$(cat "$STATE/python3.log")" = "-m http.server 9911 --bind 127.0.0.1 --directory $WORK/feed" ]
}

@test "serve --bad serves the broken feed, and another --port draws a warning" {
    make_prepared_stub
    run env PYTHON3="$STUBS/python3" "$SCRIPT" serve "$WORK" --bad --port 9000
    [ "$status" -eq 0 ]
    [[ "$output" == *"warning: the builds in $WORK ask for http://127.0.0.1:9911/appcast.xml; port 9000 will not be reached by them"* ]] || return 1
    [ "$(cat "$STATE/python3.log")" = "-m http.server 9000 --bind 127.0.0.1 --directory $WORK/feed-bad" ]
}

@test "serve refuses a folder that was not prepared and a bad port" {
    mkdir -p "$WORK"
    run env PYTHON3="$STUBS/python3" "$SCRIPT" serve "$WORK"
    [ "$status" -eq 2 ]
    [[ "$output" == *"is not a prepared rehearsal folder"* ]] || return 1
    make_prepared_stub
    run env PYTHON3="$STUBS/python3" "$SCRIPT" serve "$WORK" --port 22
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: --port must be a number from 1024 to 65535"* ]] || return 1
    [ ! -e "$STATE/python3.log" ]
}

@test "the script never enables xtrace, because it handles a signing seed" {
    run grep -nE '(^|[[:space:]])set -[A-Za-z]*x|bash -x' "$BATS_TEST_DIRNAME/../rehearse-update.sh"
    [ "$status" -eq 1 ]
}

@test "the app accepts the http://127.0.0.1 feed the rehearsal builds carry (Task 15's Interface issue)" {
    local file="$BATS_TEST_DIRNAME/../../RoomForMac/Features/Updates/DistributionInfo.swift" host
    [ -f "$file" ] || {
        echo "$file is missing: Task 5 has not landed" >&2
        return 1
    }
    for host in 127.0.0.1 localhost '::1'; do
        grep -qF -- "$host" "$file" || {
            echo "DistributionInfo.swift does not accept a loopback http feed ($host); see Task 15's Interface issue" >&2
            return 1
        }
    done
}
