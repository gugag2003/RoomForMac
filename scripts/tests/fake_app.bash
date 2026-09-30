#!/usr/bin/env bash
# Loaded by the release-script bats files (`load fake_app`), like status_stub_spy.bash.
#
# make_fake_app builds a synthetic RoomForMac.app that looks, to codesign, lipo and
# plutil, like the app a Release build produces: universal Mach-O files, Sparkle's
# framework layout, a real-looking Info.plist, and an ad-hoc signature applied
# inside-out. The check-release-app, make-dmg, make-update-archive and
# rehearse-update tests run their scripts against it, so none of them needs Xcode,
# Sparkle or a real signing identity. Nothing here touches a keychain, the
# network or anything outside the folder it is given.
#
#   make_fake_app DIR [--version X.Y.Z] [--build N] [--feed URL] [--key KEY]
#                     [--no-sparkle] [--no-hardened] [--entitlement KEY] [--xpc]
#                     [--no-entitlements]
#
#   DIR/RoomForMac.app        the app; its path is the only thing printed
#   DIR/.fake-app/            what fake_app_reseal needs (outside the app)
#
#   --version X.Y.Z    CFBundleShortVersionString (default 1.2.3)
#   --build N          CFBundleVersion (default: build_number_for of the version)
#   --feed URL         SUFeedURL (default: RFM_FEED_URL from Config/Distribution.xcconfig)
#   --key KEY          SUPublicEDKey (default: a fixed 44-character test key; "" is allowed)
#   --no-sparkle       leave Sparkle.framework out
#   --no-hardened      sign without --options runtime
#   --entitlement KEY  add KEY (true) to the app's entitlements; repeatable
#   --xpc              add Sparkle's XPC services, correctly signed, so that only the
#                      "no XPC services" check can object
#   --no-entitlements  sign the app without entitlements (the Ruling 5 fallback)  (internal to Task 9)
#
# fake_app_reseal APP             signs the app's top-level bundle again with the
#                                 options it was built with; nested code is untouched.
#                                 Run it after changing a file inside the app, so that
#                                 only the change under test can fail.        (internal to Task 9)
# fake_app_edit_plist APP ARGS..  runs `plutil ARGS.. <Info.plist>`, then fake_app_reseal.
#                                                                             (internal to Task 9)
# fake_app_entitlements_file FILE KEY..
#                                 writes an entitlements plist granting each KEY, for tests that
#                                 sign a piece of the app with entitlements by hand.
#                                                                             (internal to Task 9)
# fake_app_require_tools          skips the whole bats file when clang, codesign, lipo or plutil
#                                 is missing. Call it from setup_file: `skip` cannot work inside
#                                 the $(make_fake_app ...) a test captures the path with, so
#                                 make_fake_app itself fails with the same message instead.
# fake_app_missing_tool           prints why the app cannot be built here, or nothing.
#                                                                             (internal to Task 9)
#
# The fake tools are always /usr/bin/..., never the CODESIGN, LIPO or PLUTIL
# variables the scripts under test read, so a test that stubs one of them still
# builds its app with the real tool.

FAKE_APP_CLANG=/usr/bin/clang
FAKE_APP_CODESIGN=/usr/bin/codesign
FAKE_APP_PLUTIL=/usr/bin/plutil
FAKE_APP_LIPO=/usr/bin/lipo
FAKE_APP_KEY='ZmFrZS1hcHAtdGVzdC1rZXktbm90LWEtcmVhbC1rZXk='
FAKE_APP_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# shellcheck source=../lib/distribution.sh
source "$FAKE_APP_HERE/../lib/distribution.sh"
# shellcheck source=../lib/version.sh
source "$FAKE_APP_HERE/../lib/version.sh"

# The reason the synthetic app cannot be built here, or nothing.
fake_app_missing_tool() {
    local tool
    for tool in "$FAKE_APP_CODESIGN" "$FAKE_APP_PLUTIL" "$FAKE_APP_LIPO"; do
        if [[ ! -x "$tool" ]]; then
            printf '%s is not available; the synthetic app needs it\n' "$tool"
            return 0
        fi
    done
    if ! "$FAKE_APP_CLANG" --version > /dev/null 2>&1; then
        printf 'clang is not available (install the Xcode command line tools); the synthetic app needs it\n'
    fi
    return 0
}

fake_app_require_tools() {
    local reason
    reason="$(fake_app_missing_tool)"
    if [[ -n "$reason" ]]; then
        skip "$reason"
    fi
}

_fake_app_die() {
    printf 'make_fake_app: %s\n' "$*" >&2
    return 1
}

_fake_app_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# _fake_app_plist FILE KEY TYPE VALUE...   TYPE is string or bool (VALUE true|false)
_fake_app_plist() {
    local file="$1" key type value
    shift
    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n'
        printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        printf '<plist version="1.0">\n<dict>\n'
        while [[ $# -ge 3 ]]; do
            key="$1"
            type="$2"
            value="$3"
            shift 3
            printf '\t<key>%s</key>\n' "$key"
            if [[ "$type" == bool ]]; then
                printf '\t<%s/>\n' "$value"
            else
                printf '\t<string>%s</string>\n' "$(_fake_app_escape "$value")"
            fi
        done
        printf '</dict>\n</plist>\n'
    } > "$file"
}

# The two Mach-O files every fake bundle copies, compiled once per bats file.
# Prints the folder that holds them.
_fake_app_binaries() {
    local cache="${BATS_FILE_TMPDIR:-${TMPDIR:-/tmp}}/fake-app-binaries"
    local work
    if [[ ! -f "$cache/exe" || ! -f "$cache/dylib" ]]; then
        work="$(mktemp -d "$cache.XXXXXX")" || return 1
        printf 'int main(void) { return 0; }\n' > "$work/main.c"
        printf 'int rfm_fake_symbol(void) { return 0; }\n' > "$work/lib.c"
        "$FAKE_APP_CLANG" -arch arm64 -arch x86_64 -o "$work/exe" "$work/main.c" || return 1
        "$FAKE_APP_CLANG" -arch arm64 -arch x86_64 -dynamiclib -o "$work/dylib" "$work/lib.c" || return 1
        rm -rf "$cache"
        mv "$work" "$cache"
    fi
    printf '%s\n' "$cache"
}

# _fake_app_sign FLAGS-FILE PATH [codesign arguments]
# FLAGS-FILE holds "--options runtime" or nothing.
_fake_app_sign() {
    local flags_file="$1" path="$2" output
    shift 2
    local -a runtime=()
    if [[ -s "$flags_file" ]]; then
        runtime=(--options runtime)
    fi
    if ! output="$("$FAKE_APP_CODESIGN" --force --sign - --timestamp=none \
        ${runtime[@]+"${runtime[@]}"} "$@" "$path" 2>&1)"; then
        printf '%s\n' "$output" >&2
        _fake_app_die "codesign failed for $path"
        return 1
    fi
}

# fake_app_entitlements_file FILE KEY...   writes an entitlements plist that grants each KEY (true)
fake_app_entitlements_file() {
    local file="$1" key
    shift
    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n'
        printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        printf '<plist version="1.0">\n<dict>\n'
        for key in "$@"; do
            printf '\t<key>%s</key>\n\t<true/>\n' "$key"
        done
        printf '</dict>\n</plist>\n'
    } > "$file"
}

fake_app_reseal() {
    local app="${1%/}" state
    state="$(dirname "$app")/.fake-app"
    local -a entitlements=()
    if [[ -f "$state/entitlements.plist" ]]; then
        entitlements=(--entitlements "$state/entitlements.plist")
    fi
    _fake_app_sign "$state/runtime" "$app" ${entitlements[@]+"${entitlements[@]}"}
}

fake_app_edit_plist() {
    local app="${1%/}"
    shift
    "$FAKE_APP_PLUTIL" "$@" "$app/Contents/Info.plist" || return 1
    fake_app_reseal "$app"
}

make_fake_app() {
    local dir="${1:-}" reason
    if [[ -z "$dir" ]]; then
        _fake_app_die "needs a folder"
        return 1
    fi
    shift
    # `skip` cannot work here: callers capture the path with $(...), a subshell.
    # Put fake_app_require_tools in setup_file to skip the whole file instead.
    reason="$(fake_app_missing_tool)"
    if [[ -n "$reason" ]]; then
        _fake_app_die "$reason"
        return 1
    fi
    local version=1.2.3 build="" key="$FAKE_APP_KEY" feed=""
    local sparkle=1 hardened=1 xpc=0 with_entitlements=1
    local -a extra_entitlements=()
    local root
    root="$(cd "$FAKE_APP_HERE/../.." && pwd -P)"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version | --build | --feed | --key | --entitlement)
                if [[ $# -lt 2 ]]; then
                    _fake_app_die "$1 needs a value"
                    return 1
                fi
                case "$1" in
                    --version) version="$2" ;;
                    --build) build="$2" ;;
                    --feed) feed="$2" ;;
                    --key) key="$2" ;;
                    --entitlement) extra_entitlements+=("$2") ;;
                esac
                shift 2
                ;;
            --no-sparkle)
                sparkle=0
                shift
                ;;
            --no-hardened)
                hardened=0
                shift
                ;;
            --xpc)
                xpc=1
                shift
                ;;
            --no-entitlements)
                with_entitlements=0
                shift
                ;;
            *)
                _fake_app_die "unknown option $1"
                return 1
                ;;
        esac
    done
    if [[ -z "$feed" ]]; then
        feed="$(distribution_value "$root" RFM_FEED_URL)" || return 1
    fi
    if [[ -z "$build" ]]; then
        build="$(build_number_for "$version" 2> /dev/null)" || build=1
    fi

    local bins app state contents framework versions tool
    bins="$(_fake_app_binaries)" || return 1
    app="$dir/RoomForMac.app"
    state="$dir/.fake-app"
    contents="$app/Contents"
    rm -rf "$app" "$state"
    mkdir -p "$contents/MacOS" "$contents/Helpers" "$contents/Resources/engine/bin" "$state"

    # What fake_app_reseal needs.
    if [[ "$hardened" -eq 1 ]]; then
        echo runtime > "$state/runtime"
    else
        : > "$state/runtime"
    fi
    if [[ "$with_entitlements" -eq 1 ]]; then
        fake_app_entitlements_file "$state/entitlements.plist" \
            com.apple.security.automation.apple-events \
            com.apple.security.cs.disable-library-validation \
            ${extra_entitlements[@]+"${extra_entitlements[@]}"}
    fi

    _fake_app_plist "$contents/Info.plist" \
        CFBundleExecutable string RoomForMac \
        CFBundleIdentifier string com.roomformac.RoomForMac \
        CFBundleName string RoomForMac \
        CFBundleDisplayName string RoomForMac \
        CFBundlePackageType string APPL \
        CFBundleShortVersionString string "$version" \
        CFBundleVersion string "$build" \
        CFBundleIconName string AppIcon \
        LSMinimumSystemVersion string 26.0 \
        LSApplicationCategoryType string public.app-category.utilities \
        SUFeedURL string "$feed" \
        SUPublicEDKey string "$key" \
        SUEnableAutomaticChecks bool true \
        RFMSiteURL string "$(distribution_value "$root" RFM_SITE_URL)" \
        RFMSkipQuarantineCleanup string NO
    cp "$bins/exe" "$contents/MacOS/RoomForMac"

    # The engine's two Go tools live in Helpers; engine/bin links to them.
    printf 'fake engine\n' > "$contents/Resources/engine/VERSION"
    for tool in analyze-go status-go; do
        cp "$bins/exe" "$contents/Helpers/$tool"
        ln -s "../../../Helpers/$tool" "$contents/Resources/engine/bin/$tool"
    done

    if [[ "$sparkle" -eq 1 ]]; then
        framework="$contents/Frameworks/Sparkle.framework"
        versions="$framework/Versions/B"
        mkdir -p "$versions/Resources" "$versions/Updater.app/Contents/MacOS" "$versions/Updater.app/Contents/Resources"
        cp "$bins/dylib" "$versions/Sparkle"
        cp "$bins/exe" "$versions/Autoupdate"
        cp "$bins/exe" "$versions/Updater.app/Contents/MacOS/Updater"
        _fake_app_plist "$versions/Resources/Info.plist" \
            CFBundleExecutable string Sparkle \
            CFBundleIdentifier string org.sparkle-project.Sparkle \
            CFBundleName string Sparkle \
            CFBundlePackageType string FMWK \
            CFBundleShortVersionString string 2.10.0 \
            CFBundleVersion string 2100
        _fake_app_plist "$versions/Updater.app/Contents/Info.plist" \
            CFBundleExecutable string Updater \
            CFBundleIdentifier string org.sparkle-project.Sparkle.Updater \
            CFBundleName string Updater \
            CFBundlePackageType string APPL \
            CFBundleShortVersionString string 2.10.0 \
            CFBundleVersion string 2100
        ln -s B "$framework/Versions/Current"
        for tool in Sparkle Resources Autoupdate Updater.app; do
            ln -s "Versions/Current/$tool" "$framework/$tool"
        done
        if [[ "$xpc" -eq 1 ]]; then
            local xpc_bundle="$versions/XPCServices/org.sparkle-project.InstallerLauncher.xpc"
            mkdir -p "$xpc_bundle/Contents/MacOS"
            cp "$bins/exe" "$xpc_bundle/Contents/MacOS/InstallerLauncher"
            _fake_app_plist "$xpc_bundle/Contents/Info.plist" \
                CFBundleExecutable string InstallerLauncher \
                CFBundleIdentifier string org.sparkle-project.InstallerLauncher \
                CFBundleName string InstallerLauncher \
                CFBundlePackageType string XPC! \
                CFBundleVersion string 2100
            ln -s Versions/Current/XPCServices "$framework/XPCServices"
            _fake_app_sign "$state/runtime" "$xpc_bundle" || return 1
        fi
        _fake_app_sign "$state/runtime" "$versions/Autoupdate" \
            --identifier org.sparkle-project.Sparkle.Autoupdate || return 1
        _fake_app_sign "$state/runtime" "$versions/Updater.app" || return 1
        _fake_app_sign "$state/runtime" "$framework" || return 1
    fi

    for tool in analyze-go status-go; do
        _fake_app_sign "$state/runtime" "$contents/Helpers/$tool" \
            --identifier "com.roomformac.RoomForMac.engine.$tool" || return 1
    done
    fake_app_reseal "$app" || return 1
    printf '%s\n' "$app"
}
