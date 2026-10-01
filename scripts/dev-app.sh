#!/bin/bash
# Build the Debug app from this checkout and install it as the one development
# copy that Spotlight and Launchpad show: ~/Applications/RoomForMac Dev.app.
# A search for RoomForMac then finds the latest build and nothing else.
#
#   scripts/dev-app.sh [--open] [--keep-others] [-- <launch arguments>]
#
# - The build goes to a DerivedData folder whose name ends in .noindex, which
#   Spotlight never indexes, so the build itself is not listed. It stays under
#   ~/Library/Developer/Xcode/DerivedData: a build under ~/Desktop or
#   ~/Documents can raise a folder-access prompt (Plan 2 E6).
# - The copy is replaced only after the build succeeds. A running copy is quit
#   first.
# - Other RoomForMac bundles under ~/Library/Developer/Xcode/DerivedData are
#   build products that Spotlight lists (Xcode's own builds, older agent
#   builds, the UI-test runner). They are deleted, unless running; Xcode
#   makes them again on its next build. --keep-others keeps them. Folders
#   ending in .noindex are never touched.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BUNDLE_ID="com.roomformac.RoomForMac"

# Every outside tool and location goes through a variable, so the bats tests
# can put stubs and throwaway folders there.
XCODEBUILD="${XCODEBUILD:-xcodebuild}"
XCODEGEN="${XCODEGEN:-xcodegen}"
LSREGISTER="${LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
OPEN="${OPEN:-open}"
XCODE_DERIVED_DATA="${XCODE_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData}"
DERIVED_DATA="${RFM_DEV_DERIVED_DATA:-$XCODE_DERIVED_DATA/RoomForMac-dev.noindex}"
INSTALL="${RFM_DEV_APP:-$HOME/Applications/RoomForMac Dev.app}"

usage() {
    cat << 'EOF'
Usage: scripts/dev-app.sh [--open] [--keep-others] [-- <launch arguments>]

Builds the Debug app and installs it as ~/Applications/RoomForMac Dev.app, the
only RoomForMac that Spotlight and Launchpad list.

  --open          launch the copy afterwards, with any arguments after --
                  (for example: -- -RFMUITestScenario onboarded)
  --keep-others   keep the other RoomForMac builds in Xcode's DerivedData

Environment:
  RFM_DEV_DERIVED_DATA  the build folder; its path must end in .noindex
                        (default: ~/Library/Developer/Xcode/DerivedData/RoomForMac-dev.noindex)
  RFM_DEV_APP           the installed copy (default: ~/Applications/RoomForMac Dev.app)
EOF
}

die() {
    echo "dev-app: $*" >&2
    exit 1
}

open_after=0
keep_others=0
launch_args=()
while (($# > 0)); do
    case "$1" in
        --open) open_after=1 ;;
        --keep-others) keep_others=1 ;;
        --help | -h)
            usage
            exit 0
            ;;
        --)
            shift
            launch_args=("$@")
            break
            ;;
        *)
            usage >&2
            exit 64
            ;;
    esac
    shift
done
if ((${#launch_args[@]} > 0 && open_after == 0)); then
    die "launch arguments need --open"
fi

case "$DERIVED_DATA" in
    *.noindex | *.noindex/*) ;;
    *) die "the build folder must end in .noindex, or Spotlight lists the build too: $DERIVED_DATA" ;;
esac
[[ "$INSTALL" == *.app ]] || die "the installed copy must be an .app: $INSTALL"

# The bundle identifier of the app at $1, or nothing.
bundle_id() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2> /dev/null || true
}

# The process IDs of copies running from the bundle at $1.
running_pids() {
    local pid command
    while read -r pid command; do
        if [[ "$command" == "$1/Contents/MacOS/"* ]]; then
            echo "$pid"
        fi
    done < <(ps -axo pid=,command=)
}

# Quits every copy running from the bundle at $1, or fails.
quit_running() {
    local pids
    pids="$(running_pids "$1")"
    [[ -n "$pids" ]] || return 0
    echo "Quitting the running copy…"
    # shellcheck disable=SC2086 # one PID per word
    kill -TERM $pids 2> /dev/null || true
    for _ in {1..50}; do
        [[ -n "$(running_pids "$1")" ]] || return 0
        sleep 0.2
    done
    die "the copy at $1 is still running; quit it and run this again"
}

# The project is generated from project.yml (README, "Building the app"). The
# cache skips the work when neither the spec nor the source files changed.
"$XCODEGEN" generate --spec "$ROOT/project.yml" --project "$ROOT" --use-cache --quiet

echo "Building RoomForMac (Debug)…"
"$XCODEBUILD" -project "$ROOT/RoomForMac.xcodeproj" -scheme RoomForMac -configuration Debug \
    -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath "$DERIVED_DATA" -quiet build
BUILT="$DERIVED_DATA/Build/Products/Debug/RoomForMac.app"
[[ "$(bundle_id "$BUILT")" == "$BUNDLE_ID" ]] || die "the build did not make $BUILT"

if [[ -e "$INSTALL" && "$(bundle_id "$INSTALL")" != "$BUNDLE_ID" ]]; then
    die "$INSTALL exists and is not RoomForMac; move it away first"
fi

# The new copy is staged next to the old one under a name Spotlight skips, then
# swapped in, so a failed copy leaves the old one in place.
mkdir -p "$(dirname "$INSTALL")"
STAGE="$(dirname "$INSTALL")/.$(basename "$INSTALL" .app).$$.noindex"
trap 'rm -rf "$STAGE"' EXIT
rm -rf "$STAGE"
ditto "$BUILT" "$STAGE"
quit_running "$INSTALL"
rm -rf "$INSTALL"
mv "$STAGE" "$INSTALL"
"$LSREGISTER" -f "$INSTALL"
echo "Installed $INSTALL"

if ((keep_others == 0)); then
    shopt -s nullglob
    for other in "$XCODE_DERIVED_DATA"/*/Build/Products/*/RoomForMac*.app; do
        case "$other" in
            *.noindex/*) continue ;;
        esac
        [[ "$(bundle_id "$other")" == com.roomformac.* ]] || continue
        if [[ -n "$(running_pids "$other")" ]]; then
            echo "Kept $other: it is running"
            continue
        fi
        rm -rf "$other"
        echo "Removed $other"
    done
    shopt -u nullglob
fi

if ((open_after == 1)); then
    "$OPEN" "$INSTALL" --args ${launch_args[@]+"${launch_args[@]}"}
fi
