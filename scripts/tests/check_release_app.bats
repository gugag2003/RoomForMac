#!/usr/bin/env bats
# Checks scripts/check-release-app.sh against synthetic apps (fake_app.bash):
# universal, ad-hoc-signed bundles with Sparkle's layout that clang, codesign
# and plutil build in under a second. A passing app passes every check, and
# each mutation of it fails exactly its own check and names it. The
# designated-requirement checks run the script from a scratch copy, so they read
# a Config/ folder the test controls, with a codesign stand-in that prints the
# DR; every other call goes to the real codesign, on files in the test folder.
#
# Needs clang, codesign, lipo and plutil (any Mac with the command line tools).
# It touches no keychain, no network and nothing outside $BATS_TEST_TMPDIR.

load fake_app

setup_file() {
    fake_app_require_tools
}

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
    SCRIPT="$ROOT/scripts/check-release-app.sh"
    FAKE="$BATS_TEST_TMPDIR/fake"
    SHA=0123456789abcdef0123456789abcdef01234567
    mkdir -p "$FAKE"
    unset CODESIGN PLUTIL LIPO RFM_EXPECT_HARDENED STUB_DR
}

# The report a fully passing app prints with --adhoc --version 1.2.3.
adhoc_report() {
    cat << 'EOF'
ok: strict signature verification
ok: ad-hoc signature
ok: nested signers
ok: hardened runtime
ok: entitlements
ok: no XPC services
ok: Info.plist CFBundleIdentifier
ok: Info.plist SUFeedURL
ok: Info.plist SUPublicEDKey (skipped with --adhoc)
ok: Info.plist SUEnableAutomaticChecks
ok: Info.plist RFMSkipQuarantineCleanup
ok: Info.plist forbidden keys
ok: Info.plist LSMinimumSystemVersion
ok: Info.plist CFBundleIconName
ok: version
ok: architectures
release gate: 16 checks passed
EOF
}

# After `run`: the script failed, and exactly one check did: NAME. Any further
# arguments must appear in that check's line.
only_check_fails() {
    local name="$1" line detail
    shift
    if [[ "$status" -ne 1 ]]; then
        echo "expected exit 1, got $status: $output" >&2
        return 1
    fi
    if [[ "$(grep -c '^error: ' <<< "$output")" -ne 1 ]]; then
        echo "expected exactly one failed check: $output" >&2
        return 1
    fi
    line="$(grep '^error: ' <<< "$output")"
    if [[ "$line" != "error: $name: "* ]]; then
        echo "expected the failed check to be \"$name\": $line" >&2
        return 1
    fi
    for detail in "$@"; do
        if [[ "$line" != *"$detail"* ]]; then
            echo "expected \"$detail\" in: $line" >&2
            return 1
        fi
    done
}

# fake_root: a scratch copy of the script beside a Config/ folder the test
# controls, with the public key the synthetic apps carry and, when SHA is
# given, Config/signing-identity.sha1 holding it. Sets CHECK.
fake_root() {
    local root="$BATS_TEST_TMPDIR/root"
    mkdir -p "$root/scripts/lib" "$root/Config"
    cp "$ROOT/scripts/check-release-app.sh" "$root/scripts/"
    cp "$ROOT/scripts/lib/distribution.sh" "$ROOT/scripts/lib/version.sh" "$root/scripts/lib/"
    sed "s|^RFM_SPARKLE_PUBLIC_KEY *=.*|RFM_SPARKLE_PUBLIC_KEY = $FAKE_APP_KEY|" \
        "$ROOT/Config/Distribution.xcconfig" > "$root/Config/Distribution.xcconfig"
    if [[ $# -gt 0 ]]; then
        printf '%s\n' "$1" > "$root/Config/signing-identity.sha1"
    fi
    CHECK="$root/scripts/check-release-app.sh"
}

# A codesign that logs its calls and runs the real one, except `-d -r-`, which
# prints $STUB_DR (nothing when it is unset).
stub_dr_codesign() {
    mkdir -p "$BATS_TEST_TMPDIR/stubs"
    cat > "$BATS_TEST_TMPDIR/stubs/codesign" << 'STUB'
#!/bin/bash
echo "$*" >> "$STUB_LOG"
if [[ "$1" == -d && "$2" == -r- ]]; then
    echo "Executable=$3" >&2
    if [[ -n "${STUB_DR:-}" ]]; then
        printf '%s\n' "$STUB_DR"
    fi
    exit 0
fi
exec /usr/bin/codesign "$@"
STUB
    chmod +x "$BATS_TEST_TMPDIR/stubs/codesign"
    STUB_LOG="$BATS_TEST_TMPDIR/codesign.log"
    : > "$STUB_LOG"
    export CODESIGN="$BATS_TEST_TMPDIR/stubs/codesign" STUB_LOG
}

dr_for() {
    printf 'designated => identifier "com.roomformac.RoomForMac" and certificate leaf = H"%s"' "$1"
}

# --- the synthetic app ---

@test "make_fake_app builds a universal, strictly valid app in its own folder, fast" {
    local app started="$SECONDS" binary
    app="$(make_fake_app "$FAKE")"
    [ "$app" = "$FAKE/RoomForMac.app" ]
    [ "$((SECONDS - started))" -lt 10 ]
    [ "$(ls -A "$FAKE")" = $'.fake-app\nRoomForMac.app' ]
    run /usr/bin/codesign --verify --deep --strict "$app"
    [ "$status" -eq 0 ]
    for binary in Contents/MacOS/RoomForMac Contents/Helpers/analyze-go Contents/Helpers/status-go \
        Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle \
        Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate \
        Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater; do
        run /usr/bin/lipo -archs "$app/$binary"
        [ "$status" -eq 0 ]
        [ "$output" = "x86_64 arm64" ]
    done
}

@test "make_fake_app lays Sparkle out like the real framework, with symlinks" {
    local app framework name
    app="$(make_fake_app "$FAKE")"
    framework="$app/Contents/Frameworks/Sparkle.framework"
    [ -L "$framework/Versions/Current" ]
    [ "$(readlink "$framework/Versions/Current")" = B ]
    for name in Sparkle Resources Autoupdate Updater.app; do
        [ -L "$framework/$name" ]
        [ "$(readlink "$framework/$name")" = "Versions/Current/$name" ]
    done
    [ ! -e "$framework/XPCServices" ]
    [ -L "$app/Contents/Resources/engine/bin/status-go" ]
    [ "$(readlink "$app/Contents/Resources/engine/bin/status-go")" = "../../../Helpers/status-go" ]
}

@test "make_fake_app writes the version, build, feed and key it is given into Info.plist" {
    local app
    app="$(make_fake_app "$FAKE" --version 0.0.7 --build 42 --feed https://example.test/feed.xml --key ABC)"
    [ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")" = 0.0.7 ]
    [ "$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$app/Contents/Info.plist")" = 42 ]
    [ "$(/usr/bin/plutil -extract SUFeedURL raw -o - "$app/Contents/Info.plist")" = https://example.test/feed.xml ]
    [ "$(/usr/bin/plutil -extract SUPublicEDKey raw -o - "$app/Contents/Info.plist")" = ABC ]
    [ "$(/usr/bin/plutil -extract CFBundleIconName raw -o - "$app/Contents/Info.plist")" = AppIcon ]
}

@test "make_fake_app defaults to the repository's feed and a build number computed from the version" {
    local app
    app="$(make_fake_app "$FAKE" --version 2.3.4)"
    [ "$(/usr/bin/plutil -extract SUFeedURL raw -o - "$app/Contents/Info.plist")" = "$(distribution_value "$ROOT" RFM_FEED_URL)" ]
    [ "$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$app/Contents/Info.plist")" = 2003004 ]
}

@test "make_fake_app --xpc and --no-hardened still verify strictly, so only their own check can object" {
    local variant app
    for variant in --xpc --no-hardened --no-sparkle --no-entitlements "--entitlement com.apple.security.get-task-allow"; do
        rm -rf "$FAKE"
        mkdir -p "$FAKE"
        # shellcheck disable=SC2086 # the variant is deliberately split into words
        app="$(make_fake_app "$FAKE" $variant)"
        /usr/bin/codesign --verify --deep --strict "$app"
    done
}

@test "make_fake_app names the missing tool instead of building half an app" {
    FAKE_APP_CLANG=/nonexistent/clang run fake_app_missing_tool
    [ "$status" -eq 0 ]
    [ "$output" = "clang is not available (install the Xcode command line tools); the synthetic app needs it" ]
    FAKE_APP_CODESIGN=/nonexistent/codesign run make_fake_app "$FAKE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"make_fake_app: /nonexistent/codesign is not available"* ]] || return 1
    [ ! -e "$FAKE/RoomForMac.app" ]
    run fake_app_missing_tool
    [ -z "$output" ]
}

@test "make_fake_app refuses an unknown option and a missing value" {
    run make_fake_app "$FAKE" --no-such-option
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown option --no-such-option"* ]] || return 1
    run make_fake_app "$FAKE" --feed
    [ "$status" -eq 1 ]
    [[ "$output" == *"--feed needs a value"* ]]
}

# --- a passing app, and the report ---

@test "a synthetic app passes --adhoc --version 1.2.3, and the report is the contract" {
    local app
    app="$(make_fake_app "$FAKE")"
    run "$SCRIPT" "$app" --adhoc --version 1.2.3
    [ "$status" -eq 0 ]
    [ "$output" = "$(adhoc_report)" ]
}

@test "without --version the version check says it was not requested" {
    local app
    app="$(make_fake_app "$FAKE" --version 9.9.9)"
    run "$SCRIPT" "$app" --adhoc
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\nok: version (not requested)\n'* ]] || return 1
}

@test "a failing check does not stop the others: every check still prints its line" {
    local app
    app="$(make_fake_app "$FAKE")"
    printf 'changed after signing\n' >> "$app/Contents/Resources/engine/VERSION"
    run "$SCRIPT" "$app" --adhoc --version 1.2.3
    [ "$status" -eq 1 ]
    [ "${#lines[@]}" -eq 17 ]
    [[ "${lines[0]}" == "error: strict signature verification: "* ]] || return 1
    [ "${lines[1]}" = "ok: ad-hoc signature" ]
    [ "${lines[15]}" = "ok: architectures" ]
    [ "${lines[16]}" = "release gate: 1 of 16 checks failed" ]
}

@test "the checks read the app through CODESIGN, PLUTIL and LIPO" {
    local app tool
    app="$(make_fake_app "$FAKE")"
    mkdir -p "$BATS_TEST_TMPDIR/spies"
    for tool in codesign plutil lipo; do
        cat > "$BATS_TEST_TMPDIR/spies/$tool" << SPY
#!/bin/bash
echo "\$*" >> "$BATS_TEST_TMPDIR/spies/$tool.log"
exec /usr/bin/$tool "\$@"
SPY
        chmod +x "$BATS_TEST_TMPDIR/spies/$tool"
    done
    run env CODESIGN="$BATS_TEST_TMPDIR/spies/codesign" PLUTIL="$BATS_TEST_TMPDIR/spies/plutil" \
        LIPO="$BATS_TEST_TMPDIR/spies/lipo" "$SCRIPT" "$app" --adhoc --version 1.2.3
    [ "$status" -eq 0 ]
    for tool in codesign plutil lipo; do
        [ -s "$BATS_TEST_TMPDIR/spies/$tool.log" ]
    done
    grep -q -- '--verify --deep --strict' "$BATS_TEST_TMPDIR/spies/codesign.log"
}

@test "usage errors exit 2 before any check runs" {
    local app
    app="$(make_fake_app "$FAKE")"
    run "$SCRIPT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"no app given"* ]] || return 1
    run "$SCRIPT" "$BATS_TEST_TMPDIR/nowhere.app"
    [ "$status" -eq 2 ]
    [[ "$output" == *"is not an app bundle"* ]] || return 1
    run "$SCRIPT" "$app" --no-such-option
    [ "$status" -eq 2 ]
    run "$SCRIPT" "$app" "$app"
    [ "$status" -eq 2 ]
    run "$SCRIPT" "$app" --version
    [ "$status" -eq 2 ]
    run "$SCRIPT" "$app" --version 1.2
    [ "$status" -eq 2 ]
    [[ "$output" == *"needs a release version"* ]] || return 1
    run "$SCRIPT" "$app" --version ""
    [ "$status" -eq 2 ]
    run env RFM_EXPECT_HARDENED=2 "$SCRIPT" "$app" --adhoc
    [ "$status" -eq 2 ]
    [[ "$output" == *"RFM_EXPECT_HARDENED must be 0 or 1"* ]] || return 1
    [[ "$output" != *"ok: "* ]] || return 1
}

@test "--help prints the usage and exits 0" {
    run "$SCRIPT" --help
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "Usage: scripts/check-release-app.sh <RoomForMac.app> [--adhoc] [--version X.Y.Z] [--no-universal]" ]
}

# --- one mutation, one failed check ---

@test "Sparkle's XPC services fail only the XPC check" {
    local app
    app="$(make_fake_app "$FAKE" --xpc)"
    run "$SCRIPT" "$app" --adhoc --version 1.2.3
    only_check_fails "no XPC services" "XPCServices" "org.sparkle-project.InstallerLauncher.xpc"
}

@test "a build without the runtime flag fails only the hardened-runtime check" {
    local app
    app="$(make_fake_app "$FAKE" --no-hardened)"
    run "$SCRIPT" "$app" --adhoc --version 1.2.3
    only_check_fails "hardened runtime" "Contents/Helpers/status-go lacks the runtime flag" \
        "Sparkle.framework/Versions/B/Autoupdate lacks the runtime flag" \
        "Sparkle.framework/Versions/B/Updater.app lacks the runtime flag"
}

@test "a helper re-signed with --options 0 fails only the hardened-runtime check" {
    local app
    app="$(make_fake_app "$FAKE")"
    /usr/bin/codesign --force --sign - --timestamp=none --options 0 "$app/Contents/Helpers/status-go" 2> /dev/null
    fake_app_reseal "$app"
    run "$SCRIPT" "$app" --adhoc --version 1.2.3
    only_check_fails "hardened runtime" "Contents/Helpers/status-go lacks the runtime flag"
}

@test "get-task-allow on the app fails only the entitlements check" {
    local app
    app="$(make_fake_app "$FAKE" --entitlement com.apple.security.get-task-allow)"
    run "$SCRIPT" "$app" --adhoc --version 1.2.3
    only_check_fails "entitlements" "com.apple.security.get-task-allow"
}

@test "an extra entitlement on the app fails only the entitlements check" {
    local app
    app="$(make_fake_app "$FAKE" --entitlement com.apple.security.cs.allow-jit)"
    run "$SCRIPT" "$app" --adhoc --version 1.2.3
    only_check_fails "entitlements" "com.apple.security.cs.allow-jit"
}

@test "an app without its two entitlements fails only the entitlements check" {
    local app
    app="$(make_fake_app "$FAKE" --no-entitlements)"
    run "$SCRIPT" "$app" --adhoc --version 1.2.3
    only_check_fails "entitlements" "the app carries none" "com.apple.security.automation.apple-events=true"
}

@test "a helper that carries entitlements fails only the entitlements check, and get-task-allow is named" {
    local app
    app="$(make_fake_app "$FAKE")"
    fake_app_entitlements_file "$BATS_TEST_TMPDIR/helper.entitlements" com.apple.security.get-task-allow
    /usr/bin/codesign --force --sign - --timestamp=none --options runtime \
        --entitlements "$BATS_TEST_TMPDIR/helper.entitlements" "$app/Contents/Helpers/analyze-go" 2> /dev/null
    fake_app_reseal "$app"
    run "$SCRIPT" "$app" --adhoc --version 1.2.3
    only_check_fails "entitlements" "Contents/Helpers/analyze-go carries entitlements" \
        "Contents/Helpers/analyze-go carries com.apple.security.get-task-allow"
}

@test "an http feed fails only the feed check" {
    local app
    app="$(make_fake_app "$FAKE" --feed http://github.com/gugag2003/RoomForMac/releases/latest/download/appcast.xml)"
    run "$SCRIPT" "$app" --adhoc --version 1.2.3
    only_check_fails "Info.plist SUFeedURL" "is not an https URL"
}

@test "a different feed fails only the feed check" {
    local app
    app="$(make_fake_app "$FAKE" --feed https://example.test/appcast.xml)"
    run "$SCRIPT" "$app" --adhoc --version 1.2.3
    only_check_fails "Info.plist SUFeedURL" "is \"https://example.test/appcast.xml\", expected \"$(distribution_value "$ROOT" RFM_FEED_URL)\""
}

@test "SUVerifyUpdateBeforeExtraction fails only the forbidden-keys check" {
    local app
    app="$(make_fake_app "$FAKE")"
    fake_app_edit_plist "$app" -insert SUVerifyUpdateBeforeExtraction -bool YES
    run "$SCRIPT" "$app" --adhoc --version 1.2.3
    only_check_fails "Info.plist forbidden keys" "SUVerifyUpdateBeforeExtraction"
}

@test "every forbidden Sparkle key is named" {
    local app key
    app="$(make_fake_app "$FAKE")"
    for key in SUEnableInstallerLauncherService SUEnableDownloaderService SUVerifyUpdateBeforeExtraction \
        SURequireSignedFeed SUEnableSystemProfiling SUAutomaticallyUpdate; do
        /usr/bin/plutil -insert "$key" -bool YES "$app/Contents/Info.plist"
    done
    /usr/bin/plutil -insert SUScheduledCheckInterval -integer 3600 "$app/Contents/Info.plist"
    fake_app_reseal "$app"
    run "$SCRIPT" "$app" --adhoc --version 1.2.3
    only_check_fails "Info.plist forbidden keys" SUEnableInstallerLauncherService SUEnableDownloaderService \
        SUVerifyUpdateBeforeExtraction SURequireSignedFeed SUEnableSystemProfiling SUAutomaticallyUpdate \
        SUScheduledCheckInterval
}

@test "the other Info.plist values are pinned one by one" {
    local app
    app="$(make_fake_app "$FAKE")"
    fake_app_edit_plist "$app" -replace SUEnableAutomaticChecks -bool NO
    run "$SCRIPT" "$app" --adhoc --version 1.2.3
    only_check_fails "Info.plist SUEnableAutomaticChecks" "is \"false\", expected \"true\""
    fake_app_edit_plist "$app" -replace SUEnableAutomaticChecks -bool YES
    fake_app_edit_plist "$app" -replace RFMSkipQuarantineCleanup -string YES
    run "$SCRIPT" "$app" --adhoc --version 1.2.3
    only_check_fails "Info.plist RFMSkipQuarantineCleanup" "is \"YES\", expected \"NO\""
    fake_app_edit_plist "$app" -replace RFMSkipQuarantineCleanup -string NO
    fake_app_edit_plist "$app" -replace LSMinimumSystemVersion -string 15.0
    run "$SCRIPT" "$app" --adhoc --version 1.2.3
    only_check_fails "Info.plist LSMinimumSystemVersion" "is \"15.0\", expected \"26.0\""
    fake_app_edit_plist "$app" -replace LSMinimumSystemVersion -string 26.0
    fake_app_edit_plist "$app" -remove CFBundleIconName
    run "$SCRIPT" "$app" --adhoc --version 1.2.3
    only_check_fails "Info.plist CFBundleIconName" "is missing"
    fake_app_edit_plist "$app" -insert CFBundleIconName -string AppIcon
    fake_app_edit_plist "$app" -replace CFBundleIdentifier -string com.example.Other
    run "$SCRIPT" "$app" --adhoc --version 1.2.3
    only_check_fails "Info.plist CFBundleIdentifier" "is \"com.example.Other\", expected \"com.roomformac.RoomForMac\""
    fake_app_edit_plist "$app" -replace CFBundleIdentifier -string com.roomformac.RoomForMac
    run "$SCRIPT" "$app" --adhoc --version 1.2.3
    [ "$output" = "$(adhoc_report)" ]
}

@test "a wrong version fails only the version check, naming both fields" {
    local app
    app="$(make_fake_app "$FAKE" --version 1.2.3)"
    run "$SCRIPT" "$app" --adhoc --version 1.2.4
    only_check_fails "version" "CFBundleShortVersionString is \"1.2.3\", expected \"1.2.4\"" \
        "CFBundleVersion is \"1002003\", expected \"1002004\""
}

@test "a build number that is not the version's fails only the version check" {
    local app
    app="$(make_fake_app "$FAKE" --version 1.2.3 --build 5)"
    run "$SCRIPT" "$app" --adhoc --version 1.2.3
    only_check_fails "version" "CFBundleVersion is \"5\", expected \"1002003\""
}

@test "a thin arm64 main executable fails only the architectures check" {
    local app main
    app="$(make_fake_app "$FAKE")"
    main="$app/Contents/MacOS/RoomForMac"
    /usr/bin/lipo "$main" -thin arm64 -output "$main.thin"
    mv "$main.thin" "$main"
    fake_app_reseal "$app"
    run "$SCRIPT" "$app" --adhoc --version 1.2.3
    only_check_fails "architectures" "Contents/MacOS/RoomForMac has arm64, expected x86_64 arm64"
    run "$SCRIPT" "$app" --adhoc --version 1.2.3 --no-universal
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok: architectures (skipped with --no-universal)"* ]] || return 1
}

@test "an app without Sparkle fails every check that needs it, and only those" {
    local app
    app="$(make_fake_app "$FAKE" --no-sparkle)"
    run "$SCRIPT" "$app" --adhoc --version 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"ok: strict signature verification"* ]] || return 1
    [[ "$output" == *"error: nested signers: "*"Sparkle.framework/Versions/B/Sparkle is missing"* ]] || return 1
    [[ "$output" == *"error: hardened runtime: "*"Updater.app is missing"* ]] || return 1
    [[ "$output" == *"error: no XPC services: Contents/Frameworks/Sparkle.framework is missing"* ]] || return 1
    [[ "$output" == *"error: architectures: "*"Autoupdate is missing"* ]] || return 1
    [ "$(grep -c '^error: ' <<< "$output")" -eq 4 ]
}

# --- hardened runtime off: the Ruling 5 fallback ---

@test "RFM_EXPECT_HARDENED=0 passes an app with no runtime flag and no entitlements" {
    local app
    app="$(make_fake_app "$FAKE" --no-hardened --no-entitlements)"
    run env RFM_EXPECT_HARDENED=0 "$SCRIPT" "$app" --adhoc --version 1.2.3
    [ "$status" -eq 0 ]
    run "$SCRIPT" "$app" --adhoc --version 1.2.3
    [ "$status" -eq 1 ]
    [ "$(grep -c '^error: ' <<< "$output")" -eq 2 ]
}

@test "RFM_EXPECT_HARDENED=0 refuses a hardened app and an app that keeps the entitlements" {
    local app
    app="$(make_fake_app "$FAKE" --no-entitlements)"
    run env RFM_EXPECT_HARDENED=0 "$SCRIPT" "$app" --adhoc --version 1.2.3
    only_check_fails "hardened runtime" "carries the runtime flag, but RFM_EXPECT_HARDENED=0"
    rm -rf "$FAKE"
    mkdir -p "$FAKE"
    app="$(make_fake_app "$FAKE" --no-hardened)"
    run env RFM_EXPECT_HARDENED=0 "$SCRIPT" "$app" --adhoc --version 1.2.3
    only_check_fails "entitlements" "the app carries com.apple.security.automation.apple-events=true"
}

# --- signers ---

@test "code signed by another identity fails only the nested-signers check" {
    local app
    app="$(make_fake_app "$FAKE")"
    mkdir -p "$BATS_TEST_TMPDIR/stubs"
    cat > "$BATS_TEST_TMPDIR/stubs/codesign" << 'STUB'
#!/bin/bash
# The real codesign, except that one path reports a certificate signature.
for last; do :; done
if [[ "$1" == --display && "$2" == --verbose=2 && "$last" == "$STUB_OTHER_SIGNER" ]]; then
    /usr/bin/codesign "$@" 2>&1 | sed 's/^Signature=adhoc$/Authority=Developer ID Application: Someone Else/'
    exit 0
fi
exec /usr/bin/codesign "$@"
STUB
    chmod +x "$BATS_TEST_TMPDIR/stubs/codesign"
    run env CODESIGN="$BATS_TEST_TMPDIR/stubs/codesign" \
        STUB_OTHER_SIGNER="$app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" \
        "$SCRIPT" "$app" --adhoc --version 1.2.3
    only_check_fails "nested signers" \
        "Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate is signed by Developer ID Application: Someone Else, the app by adhoc"
}

@test "--adhoc refuses an app that is signed by a certificate" {
    local app
    app="$(make_fake_app "$FAKE")"
    mkdir -p "$BATS_TEST_TMPDIR/stubs"
    cat > "$BATS_TEST_TMPDIR/stubs/codesign" << 'STUB'
#!/bin/bash
for last; do :; done
if [[ "$1" == --display && "$2" == --verbose=2 && "$last" == "$STUB_OTHER_SIGNER" ]]; then
    /usr/bin/codesign "$@" 2>&1 | sed 's/^Signature=adhoc$/Authority=RoomForMac Self-Signed/'
    exit 0
fi
exec /usr/bin/codesign "$@"
STUB
    chmod +x "$BATS_TEST_TMPDIR/stubs/codesign"
    run env CODESIGN="$BATS_TEST_TMPDIR/stubs/codesign" STUB_OTHER_SIGNER="$app" \
        "$SCRIPT" "$app" --adhoc --version 1.2.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"error: ad-hoc signature: expected an ad-hoc signature, found RoomForMac Self-Signed"* ]] || return 1
}

# --- the designated requirement (a stubbed codesign prints it) ---

@test "a matching designated requirement passes every check without --adhoc" {
    local app
    app="$(make_fake_app "$FAKE")"
    fake_root "$SHA"
    stub_dr_codesign
    run env STUB_DR="$(dr_for "$SHA")" "$CHECK" "$app" --version 1.2.3
    [ "$status" -eq 0 ]
    [ "$output" = "$(adhoc_report | sed -e 's/^ok: ad-hoc signature$/ok: designated requirement/' \
        -e 's/^ok: Info.plist SUPublicEDKey (skipped with --adhoc)$/ok: Info.plist SUPublicEDKey/')" ]
    grep -q -- '^-d -r- ' "$STUB_LOG"
}

@test "an upper-case SHA-1 in the file matches codesign's lower-case one" {
    local app upper
    app="$(make_fake_app "$FAKE")"
    upper="$(printf '%s' "$SHA" | tr 'a-f' 'A-F')"
    fake_root "$upper"
    stub_dr_codesign
    run env STUB_DR="$(dr_for "$SHA")" "$CHECK" "$app" --version 1.2.3
    [ "$status" -eq 0 ]
}

@test "a designated requirement with a comment marker in front still matches" {
    local app
    app="$(make_fake_app "$FAKE")"
    fake_root "$SHA"
    stub_dr_codesign
    run env STUB_DR="# $(dr_for "$SHA")" "$CHECK" "$app" --version 1.2.3
    [ "$status" -eq 0 ]
}

@test "another certificate fails only the designated-requirement check" {
    local app
    app="$(make_fake_app "$FAKE")"
    fake_root "$SHA"
    stub_dr_codesign
    run env STUB_DR="$(dr_for ffffffffffffffffffffffffffffffffffffffff)" "$CHECK" "$app" --version 1.2.3
    only_check_fails "designated requirement" "certificate leaf = H\"ffffffffffffffffffffffffffffffffffffffff\"" \
        "expected identifier \"com.roomformac.RoomForMac\" and certificate leaf = H\"$SHA\""
}

@test "another bundle identifier fails only the designated-requirement check" {
    local app
    app="$(make_fake_app "$FAKE")"
    fake_root "$SHA"
    stub_dr_codesign
    run env STUB_DR="designated => identifier \"com.example.Other\" and certificate leaf = H\"$SHA\"" \
        "$CHECK" "$app" --version 1.2.3
    only_check_fails "designated requirement" "com.example.Other"
}

@test "an ad-hoc DR (a cdhash) fails only the designated-requirement check" {
    local app
    app="$(make_fake_app "$FAKE")"
    fake_root "$SHA"
    run "$CHECK" "$app" --version 1.2.3
    only_check_fails "designated requirement" "expected identifier \"com.roomformac.RoomForMac\" and certificate leaf"
}

@test "no designated requirement at all fails only that check" {
    local app
    app="$(make_fake_app "$FAKE")"
    fake_root "$SHA"
    stub_dr_codesign
    run "$CHECK" "$app" --version 1.2.3
    only_check_fails "designated requirement" "the app's is none"
}

@test "a missing Config/signing-identity.sha1 fails only the designated-requirement check" {
    local app
    app="$(make_fake_app "$FAKE")"
    fake_root
    stub_dr_codesign
    run env STUB_DR="$(dr_for "$SHA")" "$CHECK" "$app" --version 1.2.3
    only_check_fails "designated requirement" "Config/signing-identity.sha1 is missing"
    ! grep -q -- '^-d -r- ' "$STUB_LOG"
}

@test "a malformed Config/signing-identity.sha1 fails only the designated-requirement check" {
    local app malformed
    app="$(make_fake_app "$FAKE")"
    stub_dr_codesign
    for malformed in "${SHA%?}" "${SHA%?}g" "$SHA$SHA" ""; do
        fake_root "$malformed"
        run env STUB_DR="$(dr_for "$SHA")" "$CHECK" "$app" --version 1.2.3
        only_check_fails "designated requirement" "must hold exactly 40 hex digits"
    done
}

@test "--adhoc never reads Config/signing-identity.sha1 or the DR" {
    local app
    app="$(make_fake_app "$FAKE")"
    fake_root
    stub_dr_codesign
    run "$CHECK" "$app" --adhoc --version 1.2.3
    [ "$status" -eq 0 ]
    ! grep -q -- '^-d -r- ' "$STUB_LOG"
}

# --- the public key (checked without --adhoc) ---

@test "an empty public key fails only the key check, and --adhoc skips it" {
    local app
    app="$(make_fake_app "$FAKE" --key "")"
    fake_root "$SHA"
    stub_dr_codesign
    run env STUB_DR="$(dr_for "$SHA")" "$CHECK" "$app" --version 1.2.3
    only_check_fails "Info.plist SUPublicEDKey" "is missing or empty"
    run "$CHECK" "$app" --adhoc --version 1.2.3
    [ "$status" -eq 0 ]
}

@test "a public key other than the one in Config/Distribution.xcconfig fails only the key check" {
    local app
    app="$(make_fake_app "$FAKE" --key "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")"
    fake_root "$SHA"
    stub_dr_codesign
    run env STUB_DR="$(dr_for "$SHA")" "$CHECK" "$app" --version 1.2.3
    only_check_fails "Info.plist SUPublicEDKey" "expected the key in Config/Distribution.xcconfig"
}

@test "a public key that is not 44 base64 characters is refused even when both places agree" {
    local app root
    app="$(make_fake_app "$FAKE" --key "not-a-key")"
    fake_root "$SHA"
    root="$BATS_TEST_TMPDIR/root"
    sed "s|^RFM_SPARKLE_PUBLIC_KEY *=.*|RFM_SPARKLE_PUBLIC_KEY = not-a-key|" "$ROOT/Config/Distribution.xcconfig" > "$root/Config/Distribution.xcconfig"
    stub_dr_codesign
    run env STUB_DR="$(dr_for "$SHA")" "$CHECK" "$app" --version 1.2.3
    only_check_fails "Info.plist SUPublicEDKey" "is not a 44-character base64 key"
}

@test "an empty key in Config/Distribution.xcconfig fails only the key check" {
    local app root
    app="$(make_fake_app "$FAKE")"
    fake_root "$SHA"
    root="$BATS_TEST_TMPDIR/root"
    sed "s|^RFM_SPARKLE_PUBLIC_KEY *=.*|RFM_SPARKLE_PUBLIC_KEY =|" "$ROOT/Config/Distribution.xcconfig" > "$root/Config/Distribution.xcconfig"
    stub_dr_codesign
    run env STUB_DR="$(dr_for "$SHA")" "$CHECK" "$app" --version 1.2.3
    only_check_fails "Info.plist SUPublicEDKey" "RFM_SPARKLE_PUBLIC_KEY is empty in Config/Distribution.xcconfig"
}
