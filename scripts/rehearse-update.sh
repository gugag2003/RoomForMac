#!/bin/bash
# Rehearse RoomForMac's update path on this Mac, against a local feed (spike S5,
# updates half; spec §14). Three commands:
#
#   prepare <workdir>  builds the real Release app three times (0.0.1; 0.0.1 without
#                      the launch-time quarantine cleanup; 0.0.2) through the real
#                      pipeline, packages them, and writes a valid and a broken
#                      update feed and CHECKLIST.md
#   check <workdir>    runs the checks a script can do: V1, V2, V4 and V9
#   serve <workdir>    serves a feed on 127.0.0.1 for the app to update from
#
# Only the feed URL and the EdDSA key differ from a release build. They are build
# settings on the xcodebuild command line, never an edit of
# Config/Distribution.xcconfig. The script never installs, launches or quits an
# app and never touches /Applications or ~/Applications: CHECKLIST.md is for the
# owner, who does those steps by hand.
#
# A throwaway identity, for an agent that must not use the owner's (no login
# keychain involved; docs/releasing.md has the same commands):
#   scripts/make-signing-identity.sh --no-import --name "RoomForMac Rehearsal" --dir "$TMP/signing"
#   RFM_SIGNING_P12_BASE64="$(cat "$TMP/signing/identity.p12.base64")" \
#   RFM_SIGNING_P12_PASSWORD="$(cat "$TMP/signing/identity.p12.password")" \
#   RFM_SIGNING_IDENTITY_NAME="RoomForMac Rehearsal" RFM_SIGNING_EXPECTED_SHA1="" \
#       scripts/import-signing-identity.sh create "$TMP/rehearsal.keychain-db"
#   scripts/rehearse-update.sh prepare build/rehearsal --identity "RoomForMac Rehearsal" \
#       --keychain "$TMP/rehearsal.keychain-db"
#   scripts/import-signing-identity.sh delete "$TMP/rehearsal.keychain-db"

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
DEFAULT_IDENTITY="RoomForMac Self-Signed"
DEFAULT_PORT=8765
BUNDLE_ID="com.roomformac.RoomForMac"
VERSION1=0.0.1
VERSION2=0.0.2
VERSION3=0.0.3 # V5's rotated build, made by hand from CHECKLIST.md

# Every tool that builds, signs, packages or serves is called through one of
# these variables, so the bats tests can put stubs there.
XCODEGEN="${XCODEGEN:-xcodegen}"
XCODEBUILD="${XCODEBUILD:-/usr/bin/xcodebuild}"
SWIFT="${SWIFT:-/usr/bin/swift}"
CODESIGN="${CODESIGN:-/usr/bin/codesign}"
SECURITY="${SECURITY:-/usr/bin/security}"
PLUTIL="${PLUTIL:-/usr/bin/plutil}"
DITTO="${DITTO:-/usr/bin/ditto}"
TAR="${TAR:-/usr/bin/tar}"
PYTHON3="${PYTHON3:-python3}"
MAKE_DMG="${MAKE_DMG:-$ROOT/scripts/make-dmg.sh}"
MAKE_UPDATE_ARCHIVE="${MAKE_UPDATE_ARCHIVE:-$ROOT/scripts/make-update-archive.sh}"
MAKE_APPCAST="${MAKE_APPCAST:-$ROOT/scripts/make-appcast.sh}"
# SIGN_UPDATE defaults to $SPARKLE_BIN/sign_update once SPARKLE_BIN is known.

# shellcheck source=lib/version.sh
source "$ROOT/scripts/lib/version.sh"

WORK=""
IDENTITY="$DEFAULT_IDENTITY"
KEYCHAIN=""
PORT="$DEFAULT_PORT"
FEED_URL=""
DERIVED_DATA=""
PUBLIC_KEY=""
CHECKS=0
FAILURES=0
NL=$'\n'

usage() {
    cat << 'EOF'
Usage: scripts/rehearse-update.sh prepare <workdir> [--identity NAME] [--keychain PATH] [--port N]
       scripts/rehearse-update.sh check <workdir>
       scripts/rehearse-update.sh serve <workdir> [--bad] [--port N]
       scripts/rehearse-update.sh --help

prepare  builds RoomForMac 0.0.1 and 0.0.2 (Release, the real pipeline) against
         a feed at http://127.0.0.1:<port>/appcast.xml with a throwaway EdDSA key,
         builds 0.0.1 again without the quarantine cleanup, makes the disk images
         and a valid and a broken feed, and writes CHECKLIST.md. Needs an empty or
         new <workdir> under build/ or $TMPDIR, and never deletes anything.
check    V1 (signatures, no XPC services, designated requirement), V2 (the feed's
         item and signature), V4 (the broken feed is rejected) and V9 (a second
         release leaves the first item unchanged). Prints ok/error lines; exits 1
         when any check fails.
serve    python3 -m http.server on 127.0.0.1 for <workdir>/feed, or
         <workdir>/feed-bad with --bad.

  --identity NAME  code-signing identity (default "RoomForMac Self-Signed", the owner's)
  --keychain PATH  keychain that holds it, for Xcode's own signing step
  --port N         feed port, 1024 to 65535 (default 8765); baked into the builds

Set RFM_REHEARSAL_DERIVED_DATA to build outside <workdir>/dd. The repository
lives under ~/Desktop, and a build there can raise a Desktop-folder prompt
(Plan 2 E6), so an agent uses a folder under ~/Library/Developer/Xcode/DerivedData.

Exit status: 0 done; 1 a step or a check failed; 2 bad usage or a refusal.
EOF
}

usage_error() {
    printf 'error: %s\n' "$*" >&2
    printf 'Run scripts/rehearse-update.sh --help for usage.\n' >&2
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
warn() { printf 'warning: %s\n' "$*" >&2; }

need_value() {
    if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
        usage_error "$1 needs a value"
    fi
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# The identity name goes into xcodebuild settings, rehearsal.env and grep
# patterns. ASCII only, no space at either end (make-signing-identity.sh's rule).
valid_name() (
    LC_ALL=C
    case "$1" in
        "" | " "* | *" " | *[!A-Za-z0-9\ ._-]*) return 1 ;;
    esac
)

valid_port() {
    local re='^[0-9]{1,5}$' number
    [[ "$1" =~ $re ]] || return 1
    number=$((10#$1))
    [[ "$number" -ge 1024 && "$number" -le 65535 ]]
}

# Physical absolute path of $1, which need not exist yet: the deepest existing
# folder is resolved with pwd -P and the rest is appended.
physical_path() {
    local path="$1" rest="" leaf
    [[ "$path" == /* ]] || path="$PWD/$path"
    while [[ ! -d "$path" ]]; do
        leaf="$(basename "$path")"
        [[ "$leaf" != ".." ]] || usage_error "a path must not contain '..' in a part that does not exist yet: $1"
        rest="/$leaf$rest"
        path="$(dirname "$path")"
    done
    printf '%s%s\n' "$(cd "$path" && pwd -P)" "$rest"
}

# under CHILD PARENT: 0 when CHILD is PARENT or inside it. The default APFS
# volume ignores case, so the comparison does too.
under() {
    case "$(lower "$1")/" in
        "$(lower "$2")"/*) return 0 ;;
    esac
    return 1
}

have() { command -v "$1" > /dev/null 2>&1; }

state_value() {
    awk -F= -v key="$1" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$WORK/rehearsal.env"
}

require_prepared() {
    [[ -f "$WORK/rehearsal.env" ]] ||
        usage_error "$WORK is not a prepared rehearsal folder (scripts/rehearse-update.sh prepare <workdir> makes one)"
}

# step LOG WHAT COMMAND [ARGS...]: runs the command with its output in LOG. On
# failure prints the end of LOG and exits 1.
step() {
    local log="$1" what="$2"
    shift 2
    if ! "$@" > "$log" 2>&1; then
        tail -n 30 "$log" >&2
        die "$what failed; the full output is in $log"
    fi
}

# run_make_appcast LOG ARGS...: make-appcast.sh with the throwaway seed in its
# environment (never in argv), and SPARKLE_BIN for its tools. Returns its status.
run_make_appcast() {
    local log="$1"
    shift
    (
        export SPARKLE_ED_PRIVATE_KEY SPARKLE_BIN RFM_SPARKLE_PUBLIC_KEY
        SPARKLE_ED_PRIVATE_KEY="$(cat "$WORK/keys/seed")"
        RFM_SPARKLE_PUBLIC_KEY="$(cat "$WORK/keys/public")"
        "$MAKE_APPCAST" "$@"
    ) > "$log" 2>&1
}

# The facts of an appcast's newest item, as KEY=VALUE lines, and of the feed as
# a whole (items, hardware). Logic stays in bash; this only reads the XML.
appcast_facts() {
    "$PYTHON3" - "$1" << 'PY'
import sys
import xml.etree.ElementTree as ET

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
root = ET.parse(sys.argv[1]).getroot()
items = root.findall("./channel/item")
print("items=%d" % len(items))
print("hardware=%d" % len(list(root.iter(SPARKLE + "hardwareRequirements"))))
if items:
    item = items[0]
    enclosure = item.find("enclosure")
    if enclosure is None:
        enclosure = ET.Element("enclosure")

    def field(name):
        element = item.find(SPARKLE + name)
        if element is not None and element.text:
            return element.text.strip()
        return enclosure.get(SPARKLE + name, "")

    print("version=" + field("version"))
    print("short=" + field("shortVersionString"))
    print("minimum=" + field("minimumSystemVersion"))
    print("url=" + enclosure.get("url", ""))
    print("length=" + enclosure.get("length", ""))
    print("signature=" + enclosure.get(SPARKLE + "edSignature", ""))
PY
}

# fact_of FACTS KEY
fact_of() {
    printf '%s\n' "$1" | awk -F= -v key="$2" '$1 == key { sub(/^[^=]*=/, ""); print; exit }'
}

# The raw text of the item whose sparkle:version is $2, byte for byte.
appcast_item_text() {
    "$PYTHON3" - "$1" "$2" << 'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
wanted = re.escape(sys.argv[2])
pattern = r"<sparkle:version>\s*" + wanted + r"\s*</sparkle:version>" + '|sparkle:version="' + wanted + '"'
for block in re.findall(r"<item\b.*?</item>", text, re.S):
    if re.search(pattern, block):
        sys.stdout.write(block)
        sys.exit(0)
sys.exit(1)
PY
}

# corrupt_signature IN OUT: IN with the first character of its first
# sparkle:edSignature changed, so the value is still base64 but no longer valid.
corrupt_signature() {
    "$PYTHON3" - "$1" "$2" << 'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()


def flip(match):
    return match.group(1) + ("B" if match.group(2) == "A" else "A")


patched, count = re.subn(r'(sparkle:edSignature=")(.)', flip, text, count=1)
if count != 1:
    sys.exit("no sparkle:edSignature attribute in " + sys.argv[1])
open(sys.argv[2], "w", encoding="utf-8").write(patched)
PY
}

# verify_signature ARCHIVE SIGNATURE: 0 when sign_update accepts it. The throwaway
# seed reaches the tool on stdin, as in make-appcast.sh.
verify_signature() {
    "$SIGN_UPDATE" --ed-key-file - --verify "$1" "$2" < "$WORK/keys/seed" > /dev/null 2>&1
}

write_notes() {
    printf '# RoomForMac %s (rehearsal)\n\nThis build exists only to rehearse updates. It ships nowhere.\n' "$1" > "$2"
}

plist_value() {
    "$PLUTIL" -extract "$2" raw -o - "$1/Contents/Info.plist" 2> /dev/null || true
}

# ---------------------------------------------------------------- prepare

# <workdir> must be under $ROOT/build or under $TMPDIR, so a rehearsal never
# lands in a source folder or in the home folder.
workdir_allowed() {
    local temp
    temp="$(physical_path "${TMPDIR:-/tmp}")"
    under "$1" "$ROOT/build" || under "$1" "$temp"
}

check_identity() {
    local listing
    if [[ -n "$KEYCHAIN" ]]; then
        listing="$("$SECURITY" find-identity -p codesigning "$KEYCHAIN")" || die "security find-identity failed"
    else
        listing="$("$SECURITY" find-identity -p codesigning)" || die "security find-identity failed"
    fi
    grep -qF "\"$IDENTITY\"" <<< "$listing" ||
        die "no code-signing identity named \"$IDENTITY\"${KEYCHAIN:+ in $KEYCHAIN}; scripts/make-signing-identity.sh makes the default one, and this script's header shows a throwaway one"
}

make_keys() {
    local pair seed public re='^[A-Za-z0-9+/]{43}=$'
    pair="$("$SWIFT" "$ROOT/scripts/lib/ed25519-keypair.swift")" || die "could not make the throwaway EdDSA key pair"
    seed="${pair%% *}"
    public="${pair#* }"
    [[ "$seed" =~ $re && "$public" =~ $re && "$seed" != "$public" ]] ||
        die "scripts/lib/ed25519-keypair.swift did not print '<seed> <public key>' as two base64 keys"
    mkdir -p "$WORK/keys"
    chmod 700 "$WORK/keys"
    (
        umask 077
        printf '%s\n' "$seed" > "$WORK/keys/seed"
        printf '%s\n' "$public" > "$WORK/keys/public"
    )
    chmod 600 "$WORK/keys/seed" "$WORK/keys/public"
    PUBLIC_KEY="$public"
}

# build_app VERSION BUILD DEST SKIP_CLEANUP: a universal Release build through
# the real project (Prepare engine, Embed engine, Prepare Sparkle, hardened
# runtime), copied to DEST/RoomForMac.app. Only the settings below differ from a
# release build.
build_app() {
    local version="$1" build="$2" dest="$3" skip="$4" log product
    local -a flags
    log="$WORK/logs/$(basename "$dest").log"
    flags=(-project RoomForMac.xcodeproj -scheme RoomForMac -configuration Release
        -destination "generic/platform=macOS" -derivedDataPath "$DERIVED_DATA"
        "CODE_SIGN_IDENTITY=$IDENTITY")
    if [[ -n "$KEYCHAIN" ]]; then
        flags+=("OTHER_CODE_SIGN_FLAGS=--keychain $KEYCHAIN")
    fi
    flags+=("MARKETING_VERSION=$version" "CURRENT_PROJECT_VERSION=$build"
        "RFM_FEED_URL=$FEED_URL" "RFM_SPARKLE_PUBLIC_KEY=$PUBLIC_KEY"
        "RFM_SKIP_QUARANTINE_CLEANUP=$skip" build)
    say "building RoomForMac $version (build $build), quarantine cleanup skipped: $skip"
    step "$log" "the $version build" "$XCODEBUILD" "${flags[@]}"
    product="$DERIVED_DATA/Build/Products/Release/RoomForMac.app"
    [[ -d "$product" ]] || die "the $version build left no app at $product"
    mkdir -p "$dest"
    "$DITTO" --norsrc --noextattr --noacl "$product" "$dest/RoomForMac.app"
    [[ "$(plist_value "$dest/RoomForMac.app" CFBundleShortVersionString)" == "$version" ]] ||
        die "$dest/RoomForMac.app is not version $version; is $DERIVED_DATA stale?"
    [[ "$(plist_value "$dest/RoomForMac.app" CFBundleVersion)" == "$build" ]] ||
        die "$dest/RoomForMac.app is not build $build; is $DERIVED_DATA stale?"
}

# Task 3's sparkle_bin returns an explicit $SPARKLE_BIN folder as given, so the
# folder this run's builds fetched Sparkle into (the build just resolved
# project.yml's exact Sparkle pin) is handed to it that way.
find_sparkle() {
    local candidate="${SPARKLE_BIN:-$DERIVED_DATA/SourcePackages/artifacts/sparkle/Sparkle/bin}"
    # shellcheck source=lib/sparkle.sh
    source "$ROOT/scripts/lib/sparkle.sh"
    SPARKLE_BIN="$(SPARKLE_BIN="$candidate" sparkle_bin "$ROOT")" ||
        die "Sparkle's tools were not found; the builds above fetch Sparkle into $DERIVED_DATA"
    SIGN_UPDATE="${SIGN_UPDATE:-$SPARKLE_BIN/sign_update}"
}

# archive_and_appcast APP OUT_DIR APPCAST_NAME: RoomForMac-<VERSION2>.tar.xz and a
# signed appcast for it in OUT_DIR, through Task 11's scripts.
archive_and_appcast() {
    local app="$1" out="$2" name="$3" prefix="http://127.0.0.1:$PORT/"
    local archive="$out/RoomForMac-$VERSION2.tar.xz" notes="$WORK/feed/RoomForMac-$VERSION2.md" log="$WORK/logs/appcast-$3.log"
    step "$WORK/logs/archive-$name.log" "the update archive for $name" "$MAKE_UPDATE_ARCHIVE" "$app" "$archive"
    run_make_appcast "$log" --archive "$archive" --notes "$notes" --tag "v$VERSION2" --out "$out/appcast.xml" \
        --download-url-prefix "$prefix" --link "$prefix" || {
        tail -n 30 "$log" >&2
        die "make-appcast.sh failed for $name; the full output is in $log"
    }
}

write_state() {
    {
        printf 'IDENTITY=%s\n' "$IDENTITY"
        printf 'KEYCHAIN=%s\n' "$KEYCHAIN"
        printf 'PORT=%s\n' "$PORT"
        printf 'SPARKLE_BIN=%s\n' "$SPARKLE_BIN"
        printf 'DERIVED_DATA=%s\n' "$DERIVED_DATA"
    } > "$WORK/rehearsal.env"
}

checklist_template() {
    cat << 'EOF'
# Update rehearsal checklist

Made by `scripts/rehearse-update.sh prepare` for this folder. Nothing in it is a release. The builds go through the real pipeline (Prepare Sparkle, hardened runtime, the identity, `make-update-archive.sh`, `make-appcast.sh`); only the feed URL and the EdDSA key differ.

| What | Value |
|---|---|
| Workdir | `@WORK@` |
| Identity | `@IDENTITY@` |
| Feed | `@FEED_URL@` (`serve` answers it on 127.0.0.1 only) |
| Builds | `build1` = @VERSION1@ (build @BUILD1@); `build1-nocleanup` = the same without the launch-time quarantine cleanup; `build2` = @VERSION2@ (build @BUILD2@) |
| Update key | `@WORK@/keys/` (throwaway; the app trusts its public half; the seed stays in this folder) |

Rules for every step:
- Work on the owner's Mac, in a Terminal at the repository (`cd "@ROOT@"`). Record what you see in the plan's As built notes: each dialog (title and buttons), the output of every `log show` a step asks for, and the Full Disk Access state.
- The rehearsal app has the real bundle ID, and with the default identity the real certificate. A Full Disk Access or Automation grant given to it is the real app's grant. Quit RoomForMac before each install, and drag any earlier copy in `~/Applications` to the Trash first.
- Keep the feed server running in its own Terminal tab for V3 to V7 (one server per port: stop one before you start another). Its log shows every request, so an empty log means the app asked for nothing.
- Nothing here needs `sudo`. Only V6 puts an app in `/Applications`, and you drag it there yourself.

## V1. Build facts (automated)

```bash
scripts/rehearse-update.sh check "@WORK@"
```
Per build (`build1`, `build2`, `build1-nocleanup`): no XPC services in Sparkle.framework; the app, `Autoupdate`, `Updater.app` and `Sparkle.framework` signed by `@IDENTITY@`; strict deep verification; the designated requirement (`identifier "com.roomformac.RoomForMac" and certificate leaf = H"…"`), the same for all three builds; the Info.plist values `prepare` set. Expect `ok:` lines only and exit status 0.

## V2. The feed (automated)

The same `check` run: the appcast item has `sparkle:minimumSystemVersion` 26.0, no `sparkle:hardwareRequirements`, the enclosure URL and length of `feed/RoomForMac-@VERSION2@.tar.xz`, and `sign_update --verify` accepts its `edSignature`.

## V3. The first update, from a local install

Tab 1 (leave it running):
```bash
cd "@ROOT@"
scripts/rehearse-update.sh serve "@WORK@"
```
Tab 2:
```bash
mkdir -p ~/Applications
ditto "@WORK@/build1/RoomForMac.app" ~/Applications/RoomForMac.app
xattr -dr com.apple.quarantine ~/Applications/RoomForMac.app
open ~/Applications/RoomForMac.app
```
The `xattr` line is the fast path: a local build has no quarantine, so it changes nothing. This checklist is for you, not for users; V6 covers a real download.

1. Finish onboarding (the updater never starts before it ends). Grant Full Disk Access and Automation.
2. Settings > General > Updates shows **Check Now** enabled. If it says "Updates aren't set up in this build.", the app refused the `http://127.0.0.1` feed: see Task 15's Interface issue. Stop here and report it.
3. Choose RoomForMac > Check for Updates…. Sparkle may also raise its alert by itself a few seconds after launch (automatic checks are on); that is the same path. Install the update.
4. Expect: no password, App Management or Gatekeeper prompt; a relaunch into @VERSION2@; Full Disk Access, Finder and System Events still granted in Settings > Permissions, and no new Automation prompt; no quarantine on the new bundle. Then:
```bash
defaults read ~/Applications/RoomForMac.app/Contents/Info CFBundleShortVersionString   # @VERSION2@
defaults read ~/Applications/RoomForMac.app/Contents/Info CFBundleVersion              # @BUILD2@
xattr -lr ~/Applications/RoomForMac.app | grep -c com.apple.quarantine || true         # 0
codesign -dvv ~/Applications/RoomForMac.app 2>&1 | grep '^Authority='                  # Authority=@IDENTITY@
log show --info --predicate 'process == "syspolicyd"' --last 5m > "@WORK@/syspolicyd-v3.txt"
```
   Read `syspolicyd-v3.txt` for assessments of RoomForMac and record them. The update arrived over `http://127.0.0.1`, so record that App Transport Security needed no exception. Console may show Sparkle's warning that the feed URL may need to use HTTPS: it is expected for this local feed, and not a failure.
5. Menu-bar only (Plan 3, Ruling 8). Reinstall build1 and finish onboarding again if asked. Close the main window so only the menu-bar extra shows, then press ⌘-Tab to RoomForMac. Expect the app menu to still hold Check for Updates…. Use it: Sparkle's alert comes forward. After the update the relaunched app opens its window (Ruling 8: a normal launch, not a login launch).
6. A clean while updating (Plan 3, Ruling 8). Reinstall build1. Choose Check for Updates… and let Sparkle download until it offers **Install and Relaunch**, without clicking it. Start a Smart Clean clean that takes more than 30 seconds (select the largest items), then click **Install and Relaunch** while it runs. Expect the relaunch to wait until the clean ends, and no quit prompt ("Stop and Quit", "Quit When Done") to appear. Record the order of events.

## V4. A refused update

- **Tool level (automated):** `check` proves that `sign_update --verify` rejects the corrupted signature in `feed-bad/appcast.xml`, and that its archive holds an ad-hoc signed app. Sparkle accepts an update when either the EdDSA signature or the code signature matches the installed app, so a corrupted EdDSA signature on an archive signed with the app's own certificate would (rightly) install. That is why the bad feed's archive is signed ad hoc: neither check can pass.
- **In the app:** reinstall build1 as in V3. Stop the server, then:
```bash
scripts/rehearse-update.sh serve "@WORK@" --bad
```
  Choose Check for Updates…. Expect Sparkle to refuse: an alert that the update could not be validated. Record its exact text, then:
```bash
defaults read ~/Applications/RoomForMac.app/Contents/Info CFBundleShortVersionString   # still @VERSION1@
log show --info --last 5m --predicate 'process == "RoomForMac" AND eventMessage CONTAINS[c] "sign"' > "@WORK@/signature-v4.txt"
```
  `signature-v4.txt` should hold Sparkle's signature error, and the app's own `updates` log line (Task 5's `updater(_:didAbortWithError:)`).

## V5. Key rotation

Build @VERSION3@ with a second throwaway key and the same certificate. Build @VERSION2@ (`build2`) must accept it.
```bash
cd "@ROOT@"
KEYS="$(swift scripts/lib/ed25519-keypair.swift)"        # "<seed> <public key>"
ROTATED_SEED="${KEYS%% *}"
ROTATED_PUBLIC="${KEYS#* }"
xcodegen generate
xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMac -configuration Release \
    -destination "generic/platform=macOS" -derivedDataPath "@DERIVED_DATA@" \
    CODE_SIGN_IDENTITY="@IDENTITY@" @KEYCHAIN_ARG@\
    MARKETING_VERSION=@VERSION3@ CURRENT_PROJECT_VERSION=@BUILD3@ \
    RFM_FEED_URL="@FEED_URL@" RFM_SPARKLE_PUBLIC_KEY="$ROTATED_PUBLIC" \
    RFM_SKIP_QUARANTINE_CLEANUP=NO build
mkdir -p "@WORK@/feed-rotated"
scripts/make-update-archive.sh "@DERIVED_DATA@/Build/Products/Release/RoomForMac.app" \
    "@WORK@/feed-rotated/RoomForMac-@VERSION3@.tar.xz"
printf '# RoomForMac @VERSION3@ (rehearsal)\n\nThe key rotation build.\n' > "@WORK@/feed-rotated/RoomForMac-@VERSION3@.md"
SPARKLE_BIN="@SPARKLE_BIN@" RFM_SPARKLE_PUBLIC_KEY="$ROTATED_PUBLIC" SPARKLE_ED_PRIVATE_KEY="$ROTATED_SEED" scripts/make-appcast.sh \
    --archive "@WORK@/feed-rotated/RoomForMac-@VERSION3@.tar.xz" \
    --notes "@WORK@/feed-rotated/RoomForMac-@VERSION3@.md" --tag v@VERSION3@ \
    --out "@WORK@/feed-rotated/appcast.xml" \
    --download-url-prefix "http://127.0.0.1:@PORT@/" --link "http://127.0.0.1:@PORT@/"
```
Install `build2` as in V3 (`ditto "@WORK@/build2/RoomForMac.app" …`), then serve the rotated feed and update:
```bash
python3 -m http.server @PORT@ --bind 127.0.0.1 --directory "@WORK@/feed-rotated"
```
Expect the update to install with no extra prompt: the EdDSA check against the old key fails, and the certificate check passes. Then `defaults read ~/Applications/RoomForMac.app/Contents/Info SUPublicEDKey` prints the value of `echo "$ROTATED_PUBLIC"`, and Full Disk Access is intact. This is Ruling 19's rotation path.

## V6. The first update after Open Anyway (U2), with and without the cleanup

This is the real first-download path, and the one the research could not verify: the bundle you approve with Open Anyway may still carry quarantine on nested files such as `Autoupdate`. Run it twice: once from `dmg/` (the app strips its own quarantine at launch) and once from `dmg-nocleanup/` (it does not). Drag `/Applications/RoomForMac.app` to the Trash between the two runs.

1. Serve the disk image from a second tab and download it with **Safari**, so that it is quarantined (a `curl` download would not be):
```bash
python3 -m http.server 8766 --bind 127.0.0.1 --directory "@WORK@/dmg"
```
   Safari: `http://127.0.0.1:8766/RoomForMac-@VERSION1@.dmg`. For the second run, stop that server and use `--directory "@WORK@/dmg-nocleanup"`.
2. Open the downloaded image, drag RoomForMac onto Applications, and eject the image. `xattr -l /Applications/RoomForMac.app` shows `com.apple.quarantine`.
3. Open RoomForMac. macOS says “RoomForMac” Not Opened: click Done, then System Settings > Privacy & Security > Open Anyway, click Open Anyway again and enter your login password. Finish onboarding and grant the permissions.
4. Before updating, record the quarantine that is left:
```bash
xattr -lr /Applications/RoomForMac.app | grep -c com.apple.quarantine || true
xattr -l /Applications/RoomForMac.app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate
```
   With `dmg` the count is 0 shortly after launch. With `dmg-nocleanup` it stays above 0.
5. Start the feed (tab 1, `scripts/rehearse-update.sh serve "@WORK@"`) and choose RoomForMac > Check for Updates… and install.
6. Expect no Gatekeeper, "damaged" or App Management dialog, a relaunch into @VERSION2@, and Full Disk Access intact. Record any dialog and the output of:
```bash
log show --info --predicate 'process == "syspolicyd"' --last 5m > "@WORK@/syspolicyd-v6.txt"
```
   Reading the two runs together:
   - `dmg` passes: Ruling 9's cleanup works.
   - `dmg-nocleanup` also passes: the cleanup is harmless but not needed on this macOS. Keep it (Ruling 9).
   - `dmg-nocleanup` fails and `dmg` passes: the cleanup is what makes the first update work.
   - `dmg` fails: stop before the first public release and report the dialog.

## V7. A standard user

1. In System Settings > Users & Groups, add a Standard user, and switch to it with Fast User Switching. Your tab 1 keeps serving: 127.0.0.1 is shared by every account.
2. From your own account, put a copy where both can read it:
```bash
mkdir -p /Users/Shared/rfm-rehearsal
ditto "@WORK@/build1/RoomForMac.app" /Users/Shared/rfm-rehearsal/RoomForMac.app
```
3. In the standard user's Terminal:
```bash
mkdir -p ~/Applications
ditto /Users/Shared/rfm-rehearsal/RoomForMac.app ~/Applications/RoomForMac.app
xattr -dr com.apple.quarantine ~/Applications/RoomForMac.app
open ~/Applications/RoomForMac.app
```
4. Finish onboarding (this user's grants are its own), then choose Check for Updates…. Expect what V3 expects: no password or App Management prompt, and a relaunch into @VERSION2@.
5. Afterwards delete `/Users/Shared/rfm-rehearsal` and the user.

## V8. Development builds and UI-test scenarios make no request

The server log of V3 is the control: a request from the Release build shows there, so an empty log here means something.
```bash
cd "@ROOT@"
xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMac -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/RoomForMac-plan6" \
    CODE_SIGN_IDENTITY="@IDENTITY@" @KEYCHAIN_ARG@\
    RFM_FEED_URL="@FEED_URL@" RFM_SPARKLE_PUBLIC_KEY="$(cat "@WORK@/keys/public")" build
DEBUG_APP="$HOME/Library/Developer/Xcode/DerivedData/RoomForMac-plan6/Build/Products/Debug/RoomForMac.app"
open -n "$DEBUG_APP"
```
1. With `scripts/rehearse-update.sh serve "@WORK@"` running, wait a minute. Expect an empty server log, and Settings > General showing only the note "Development builds don't check for updates." (no switches, no Check Now). Quit the app with ⌘Q.
2. Then a scenario:
```bash
open -n "$DEBUG_APP" --args -RFMUITestScenario onboarded
```
   Expect an empty server log, and no Updates section at all in Settings > General.

## V9. Two releases (automated)

`check` builds an appcast for @VERSION1@, then one for @VERSION2@ with `--previous`, using the real builds and Sparkle's real tools: two items, the @VERSION1@ item byte-identical and still pointing at its own tag's download URL.

## V10. macOS 26

Repeat V3 and V6 on a Mac running macOS 26, the users' floor. Copy this folder there without a browser or AirDrop, which add quarantine:
```bash
rsync -a --exclude dd --exclude logs "@WORK@/" "<the other Mac>:rehearsal/"
```
There, replace tab 1 with `python3 -m http.server @PORT@ --bind 127.0.0.1 --directory ~/rehearsal/feed`, and use `~/rehearsal/build1`, `~/rehearsal/dmg` and `~/rehearsal/dmg-nocleanup` in place of the paths above. The apps are already signed, so that Mac needs no identity.

## When you are done

Drag the rehearsal copies of RoomForMac to the Trash. With a throwaway identity, remove its Full Disk Access entry in System Settings > Privacy & Security and run `tccutil reset AppleEvents com.roomformac.RoomForMac`; with the default identity the grants are the real app's, so leave them.

## Results

| Step | macOS 27 | macOS 26 | Dialogs, log lines, notes |
|---|---|---|---|
| V1, V2, V4 tool level, V9 (`check`) | | | |
| V3 update from a local install | | | |
| V3 menu-bar only, and a clean while updating | | | |
| V4 in the app | | | |
| V5 key rotation | | | |
| V6 with the cleanup | | | |
| V6 without the cleanup | | | |
| V7 standard user | | | |
| V8 Debug and scenario | | | |
EOF
}

# render_checklist: the template with every @NAME@ replaced by its value. Python's
# str.replace is literal, so no path or key can break the substitution.
render_checklist() {
    local keychain_arg=""
    if [[ -n "$KEYCHAIN" ]]; then
        keychain_arg="OTHER_CODE_SIGN_FLAGS=\"--keychain $KEYCHAIN\" "
    fi
    checklist_template | "$PYTHON3" -c '
import sys

text = sys.stdin.read()
pairs = sys.argv[1:]
for name, value in zip(pairs[0::2], pairs[1::2]):
    text = text.replace("@" + name + "@", value)
sys.stdout.write(text)
' \
        WORK "$WORK" ROOT "$ROOT" PORT "$PORT" IDENTITY "$IDENTITY" KEYCHAIN_ARG "$keychain_arg" \
        DERIVED_DATA "$DERIVED_DATA" FEED_URL "$FEED_URL" SPARKLE_BIN "$SPARKLE_BIN" \
        VERSION1 "$VERSION1" VERSION2 "$VERSION2" VERSION3 "$VERSION3" \
        BUILD1 "$BUILD1" BUILD2 "$BUILD2" BUILD3 "$BUILD3"
}

cmd_prepare() {
    local workdir="" tool folder
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --identity)
                need_value "$@"
                IDENTITY="$2"
                shift 2
                ;;
            --keychain)
                need_value "$@"
                KEYCHAIN="$2"
                shift 2
                ;;
            --port)
                need_value "$@"
                PORT="$2"
                shift 2
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            -*) usage_error "unknown argument: $1" ;;
            *)
                [[ -z "$workdir" ]] || usage_error "unexpected argument: $1"
                workdir="$1"
                shift
                ;;
        esac
    done
    [[ -n "$workdir" ]] || usage_error "prepare needs a <workdir>"
    valid_port "$PORT" || usage_error "--port must be a number from 1024 to 65535"
    valid_name "$IDENTITY" ||
        usage_error "--identity may contain only ASCII letters, digits, spaces (not at either end), dots, dashes and underscores"
    if [[ -n "$KEYCHAIN" ]]; then
        case "$KEYCHAIN" in
            *[[:space:]]*) usage_error "--keychain must not contain spaces: Xcode hands it to codesign inside one flag string" ;;
        esac
        [[ "$KEYCHAIN" == /* ]] || KEYCHAIN="$PWD/$KEYCHAIN"
        [[ -f "$KEYCHAIN" ]] || usage_error "keychain not found: $KEYCHAIN"
    fi

    WORK="$(physical_path "$workdir")"
    workdir_allowed "$WORK" ||
        refuse "<workdir> must be under $ROOT/build or under \$TMPDIR, not $WORK"
    if [[ -e "$WORK" && -n "$(ls -A "$WORK" 2> /dev/null)" ]]; then
        refuse "$WORK is not empty; remove it first (this script never deletes a rehearsal)"
    fi

    have "$XCODEGEN" || die "xcodegen not found (brew install xcodegen)"
    have "$XCODEBUILD" || die "xcodebuild not found"
    have "$SWIFT" || die "swift not found"
    have "$PYTHON3" || die "python3 not found"
    have "$DITTO" || die "ditto not found"
    for tool in "$MAKE_DMG" "$MAKE_UPDATE_ARCHIVE" "$MAKE_APPCAST"; do
        [[ -x "$tool" ]] || die "$tool is missing or not executable"
    done
    check_identity

    BUILD1="$(build_number_for "$VERSION1")"
    BUILD2="$(build_number_for "$VERSION2")"
    BUILD3="$(build_number_for "$VERSION3")"
    FEED_URL="http://127.0.0.1:$PORT/appcast.xml"
    DERIVED_DATA="${RFM_REHEARSAL_DERIVED_DATA:-$WORK/dd}"
    [[ "$DERIVED_DATA" == /* ]] || DERIVED_DATA="$PWD/$DERIVED_DATA"
    for folder in Desktop Documents; do
        if under "$(physical_path "$DERIVED_DATA")" "$(physical_path "$HOME")/$folder"; then
            warn "DerivedData $DERIVED_DATA is under ~/$folder; a build there can raise a $folder prompt (Plan 2 E6). Set RFM_REHEARSAL_DERIVED_DATA to a folder under ~/Library/Developer/Xcode/DerivedData."
        fi
    done

    cd "$ROOT"
    mkdir -p "$WORK/logs" "$WORK/feed" "$WORK/feed-bad" "$WORK/dmg" "$WORK/dmg-nocleanup"
    make_keys

    say "generating the Xcode project"
    step "$WORK/logs/xcodegen.log" "xcodegen" "$XCODEGEN" generate
    build_app "$VERSION1" "$BUILD1" "$WORK/build1" NO
    build_app "$VERSION1" "$BUILD1" "$WORK/build1-nocleanup" YES
    build_app "$VERSION2" "$BUILD2" "$WORK/build2" NO
    find_sparkle

    say "making the disk images for V6"
    step "$WORK/logs/dmg.log" "make-dmg.sh (build1)" "$MAKE_DMG" "$WORK/build1/RoomForMac.app" "$WORK/dmg/RoomForMac-$VERSION1.dmg"
    step "$WORK/logs/dmg-nocleanup.log" "make-dmg.sh (build1-nocleanup)" \
        "$MAKE_DMG" "$WORK/build1-nocleanup/RoomForMac.app" "$WORK/dmg-nocleanup/RoomForMac-$VERSION1.dmg"

    say "making the valid feed (feed/)"
    write_notes "$VERSION2" "$WORK/feed/RoomForMac-$VERSION2.md"
    archive_and_appcast "$WORK/build2/RoomForMac.app" "$WORK/feed" good

    # Sparkle accepts an update when EITHER the EdDSA signature OR the code
    # signature matches the installed app's designated requirement. A corrupted
    # EdDSA signature on an archive with the app's own certificate would
    # therefore install, correctly. The broken feed carries an ad-hoc signed
    # copy, so neither check can pass and V4's refusal is real.
    say "making the broken feed (feed-bad/): ad-hoc signed archive, corrupted edSignature"
    mkdir -p "$WORK/bad-src/app" "$WORK/bad-src/out"
    "$DITTO" --norsrc --noextattr --noacl "$WORK/build2/RoomForMac.app" "$WORK/bad-src/app/RoomForMac.app"
    step "$WORK/logs/adhoc.log" "re-signing the copy ad hoc" \
        "$CODESIGN" --force --deep --sign - --timestamp=none --options runtime "$WORK/bad-src/app/RoomForMac.app"
    archive_and_appcast "$WORK/bad-src/app/RoomForMac.app" "$WORK/bad-src/out" bad
    mv "$WORK/bad-src/out/RoomForMac-$VERSION2.tar.xz" "$WORK/feed-bad/RoomForMac-$VERSION2.tar.xz"
    corrupt_signature "$WORK/bad-src/out/appcast.xml" "$WORK/feed-bad/appcast.xml"
    rm -rf "$WORK/bad-src"

    write_state
    render_checklist > "$WORK/CHECKLIST.md"
    say "ready: $WORK"
    printf '    1. scripts/rehearse-update.sh check "%s"\n' "$WORK"
    printf '    2. follow %s/CHECKLIST.md (V3 to V8 and V10 need you)\n' "$WORK"
}

# ------------------------------------------------------------------ check

pass() {
    CHECKS=$((CHECKS + 1))
    printf 'ok: %s\n' "$*"
}
fail() {
    CHECKS=$((CHECKS + 1))
    FAILURES=$((FAILURES + 1))
    printf 'error: %s\n' "$*"
}

# has_authority PATH: PATH's signature chain names the identity.
has_authority() {
    local info
    info="$("$CODESIGN" -dvv "$1" 2>&1)" || return 1
    grep -qxF "Authority=$IDENTITY" <<< "$info"
}

# check_app NAME VERSION BUILD SKIP: V1 for one build. Sets APP_DR.
check_app() {
    local name="$1" version="$2" build="$3" skip="$4"
    local app="$WORK/$name/RoomForMac.app" framework rel path found bad="" mismatch=""
    framework="$app/Contents/Frameworks/Sparkle.framework"
    APP_DR=""
    if [[ ! -d "$app" ]]; then
        fail "V1 $name: no app at $app"
        return 0
    fi

    if [[ ! -d "$framework" ]]; then
        fail "V1 $name: the app has no Sparkle.framework"
    else
        found="$(find "$framework" \( -name XPCServices -o -name '*.xpc' \) -print 2> /dev/null || true)"
        if [[ -z "$found" ]]; then
            pass "V1 $name: Sparkle.framework has no XPC services"
        else
            fail "V1 $name: Sparkle.framework still has XPC services, for example ${found%%"$NL"*}"
        fi
    fi

    for rel in "" Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate \
        Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app Contents/Frameworks/Sparkle.framework; do
        path="$app${rel:+/$rel}"
        if ! has_authority "$path"; then
            bad="$bad ${rel:-RoomForMac.app}"
        fi
    done
    if [[ -z "$bad" ]]; then
        pass "V1 $name: the app, Autoupdate, Updater.app and Sparkle.framework are signed by \"$IDENTITY\""
    else
        fail "V1 $name: not signed by \"$IDENTITY\":$bad"
    fi

    if "$CODESIGN" --verify --deep --strict "$app" > /dev/null 2>&1; then
        pass "V1 $name: strict deep verification passes"
    else
        fail "V1 $name: codesign --verify --deep --strict fails"
    fi

    APP_DR="$("$CODESIGN" -d -r- "$app" 2> /dev/null | sed -n 's/^designated => //p' || true)"
    if [[ "$APP_DR" == 'identifier "'"$BUNDLE_ID"'" and certificate leaf = H"'* ]]; then
        pass "V1 $name: the designated requirement pins $BUNDLE_ID and the certificate leaf"
    else
        fail "V1 $name: unexpected designated requirement: ${APP_DR:-none}"
    fi

    [[ "$(plist_value "$app" CFBundleIdentifier)" == "$BUNDLE_ID" ]] || mismatch="$mismatch CFBundleIdentifier"
    [[ "$(plist_value "$app" CFBundleShortVersionString)" == "$version" ]] || mismatch="$mismatch CFBundleShortVersionString"
    [[ "$(plist_value "$app" CFBundleVersion)" == "$build" ]] || mismatch="$mismatch CFBundleVersion"
    [[ "$(plist_value "$app" SUFeedURL)" == "$FEED_URL" ]] || mismatch="$mismatch SUFeedURL"
    [[ "$(plist_value "$app" SUPublicEDKey)" == "$(cat "$WORK/keys/public")" ]] || mismatch="$mismatch SUPublicEDKey"
    [[ "$(plist_value "$app" RFMSkipQuarantineCleanup)" == "$skip" ]] || mismatch="$mismatch RFMSkipQuarantineCleanup"
    if [[ -z "$mismatch" ]]; then
        pass "V1 $name: Info.plist says $version ($build), the rehearsal feed and key, RFMSkipQuarantineCleanup $skip"
    else
        fail "V1 $name: Info.plist differs from what prepare set in:$mismatch"
    fi
}

# check_good_feed: V2. Sets GOOD_SIGNATURE and GOOD_VERIFIED.
check_good_feed() {
    local appcast="$WORK/feed/appcast.xml" archive="$WORK/feed/RoomForMac-$VERSION2.tar.xz"
    local facts problems="" size
    GOOD_SIGNATURE=""
    GOOD_VERIFIED=0
    if [[ ! -f "$appcast" || ! -f "$archive" ]]; then
        fail "V2 feed: appcast.xml or RoomForMac-$VERSION2.tar.xz is missing from $WORK/feed"
        return 0
    fi
    if ! facts="$(appcast_facts "$appcast" 2>&1)"; then
        fail "V2 feed: appcast.xml is not readable XML"
        return 0
    fi
    GOOD_SIGNATURE="$(fact_of "$facts" signature)"
    size="$(stat -f %z "$archive")"
    [[ "$(fact_of "$facts" items)" == 1 ]] || problems="$problems items($(fact_of "$facts" items))"
    [[ "$(fact_of "$facts" version)" == "$BUILD2" ]] || problems="$problems sparkle:version($(fact_of "$facts" version))"
    [[ "$(fact_of "$facts" short)" == "$VERSION2" ]] || problems="$problems shortVersionString($(fact_of "$facts" short))"
    [[ "$(fact_of "$facts" minimum)" == 26.0 ]] || problems="$problems minimumSystemVersion($(fact_of "$facts" minimum))"
    [[ "$(fact_of "$facts" hardware)" == 0 ]] || problems="$problems hardwareRequirements($(fact_of "$facts" hardware))"
    [[ "$(fact_of "$facts" url)" == "http://127.0.0.1:$PORT/RoomForMac-$VERSION2.tar.xz" ]] || problems="$problems url($(fact_of "$facts" url))"
    [[ "$(fact_of "$facts" length)" == "$size" ]] || problems="$problems length($(fact_of "$facts" length), the archive has $size)"
    [[ -n "$GOOD_SIGNATURE" ]] || problems="$problems edSignature(missing)"
    if [[ -z "$problems" ]]; then
        pass "V2 feed: one item, build $BUILD2 ($VERSION2), minimumSystemVersion 26.0, no hardware requirements, the right URL and length"
    else
        fail "V2 feed: the item is wrong in:$problems"
    fi
    if [[ -n "$GOOD_SIGNATURE" ]] && verify_signature "$archive" "$GOOD_SIGNATURE"; then
        GOOD_VERIFIED=1
        pass "V2 feed: sign_update --verify accepts the archive's edSignature"
    else
        fail "V2 feed: sign_update --verify rejects the archive's edSignature"
    fi
}

# check_bad_feed: V4 at the tool level. The in-app half is in CHECKLIST.md.
check_bad_feed() {
    local appcast="$WORK/feed-bad/appcast.xml" archive="$WORK/feed-bad/RoomForMac-$VERSION2.tar.xz"
    local facts bad info
    if [[ "$GOOD_VERIFIED" != 1 ]]; then
        fail "V4 feed-bad: not run, because V2's sign_update --verify did not pass and a rejection would prove nothing"
        return 0
    fi
    if [[ ! -f "$appcast" || ! -f "$archive" ]]; then
        fail "V4 feed-bad: appcast.xml or RoomForMac-$VERSION2.tar.xz is missing from $WORK/feed-bad"
        return 0
    fi
    if ! facts="$(appcast_facts "$appcast" 2>&1)"; then
        fail "V4 feed-bad: appcast.xml is not readable XML"
        return 0
    fi
    bad="$(fact_of "$facts" signature)"
    if [[ -z "$bad" || "$bad" == "$GOOD_SIGNATURE" ]]; then
        fail "V4 feed-bad: its edSignature is missing or not corrupted"
        return 0
    fi
    if verify_signature "$archive" "$bad" || verify_signature "$WORK/feed/RoomForMac-$VERSION2.tar.xz" "$bad"; then
        fail "V4 feed-bad: sign_update --verify accepts the corrupted edSignature"
    else
        pass "V4 feed-bad: sign_update --verify rejects the corrupted edSignature"
    fi
    mkdir -p "$CHECK_TMP/bad"
    if "$TAR" -xJf "$archive" -C "$CHECK_TMP/bad" 2> /dev/null &&
        info="$("$CODESIGN" -dvv "$CHECK_TMP/bad/RoomForMac.app" 2>&1)" &&
        grep -qxF 'Signature=adhoc' <<< "$info"; then
        pass "V4 feed-bad: its archive holds an ad-hoc signed app, so the certificate check cannot rescue the update either"
    else
        fail "V4 feed-bad: its archive does not hold an ad-hoc signed RoomForMac.app"
    fi
}

# check_two_releases: V9 with the real builds. 0.0.1 first, then 0.0.2 with
# --previous: the feed must hold both items, the first one unchanged.
check_two_releases() {
    local dir="$WORK/v9" prefix1 prefix2 old_before old_after facts
    prefix1="http://127.0.0.1:$PORT/releases/download/v$VERSION1/"
    prefix2="http://127.0.0.1:$PORT/releases/download/v$VERSION2/"
    rm -rf "$dir"
    mkdir -p "$dir"
    write_notes "$VERSION1" "$dir/$VERSION1.md"
    if ! "$MAKE_UPDATE_ARCHIVE" "$WORK/build1/RoomForMac.app" "$dir/RoomForMac-$VERSION1.tar.xz" > "$dir/archive.log" 2>&1; then
        fail "V9: the $VERSION1 archive could not be made (see $dir/archive.log)"
        return 0
    fi
    if ! run_make_appcast "$dir/first.log" --archive "$dir/RoomForMac-$VERSION1.tar.xz" --notes "$dir/$VERSION1.md" \
        --tag "v$VERSION1" --out "$dir/appcast-first.xml" --download-url-prefix "$prefix1" --link "http://127.0.0.1:$PORT/"; then
        fail "V9: make-appcast.sh failed for the first release (see $dir/first.log)"
        return 0
    fi
    if ! run_make_appcast "$dir/second.log" --archive "$WORK/feed/RoomForMac-$VERSION2.tar.xz" \
        --notes "$WORK/feed/RoomForMac-$VERSION2.md" --tag "v$VERSION2" --out "$dir/appcast-second.xml" \
        --previous "$dir/appcast-first.xml" --download-url-prefix "$prefix2" --link "http://127.0.0.1:$PORT/"; then
        fail "V9: make-appcast.sh failed for the second release (see $dir/second.log)"
        return 0
    fi
    facts="$(appcast_facts "$dir/appcast-second.xml" 2>&1)" || {
        fail "V9: the second appcast is not readable XML"
        return 0
    }
    if [[ "$(fact_of "$facts" items)" == 2 && "$(fact_of "$facts" version)" == "$BUILD2" ]] &&
        [[ "$(fact_of "$facts" url)" == "${prefix2}RoomForMac-$VERSION2.tar.xz" ]]; then
        pass "V9: the second feed has two items, the new one first, with the $VERSION2 download URL"
    else
        fail "V9: the second feed should have two items with $VERSION2 first; it says: $(printf '%s' "$facts" | tr '\n' ' ')"
    fi
    old_before="$(appcast_item_text "$dir/appcast-first.xml" "$BUILD1" 2> /dev/null)" || old_before=""
    old_after="$(appcast_item_text "$dir/appcast-second.xml" "$BUILD1" 2> /dev/null)" || old_after=""
    if [[ -n "$old_before" && "$old_before" == "$old_after" ]] && grep -qF "${prefix1}RoomForMac-$VERSION1.tar.xz" <<< "$old_after"; then
        pass "V9: the $VERSION1 item is byte-identical in the second feed and keeps its own download URL"
    else
        fail "V9: the $VERSION1 item changed, or is missing, in the second feed"
    fi
}

cmd_check() {
    local workdir="" spec name version build skip drs="" first
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help)
                usage
                exit 0
                ;;
            -*) usage_error "unknown argument: $1" ;;
            *)
                [[ -z "$workdir" ]] || usage_error "unexpected argument: $1"
                workdir="$1"
                shift
                ;;
        esac
    done
    [[ -n "$workdir" ]] || usage_error "check needs a <workdir>"
    WORK="$(physical_path "$workdir")"
    require_prepared

    IDENTITY="$(state_value IDENTITY)"
    PORT="$(state_value PORT)"
    SPARKLE_BIN="${SPARKLE_BIN:-$(state_value SPARKLE_BIN)}"
    [[ -n "$IDENTITY" && -n "$PORT" && -n "$SPARKLE_BIN" ]] || die "$WORK/rehearsal.env is incomplete; prepare the rehearsal again"
    SIGN_UPDATE="${SIGN_UPDATE:-$SPARKLE_BIN/sign_update}"
    FEED_URL="http://127.0.0.1:$PORT/appcast.xml"
    have "$PYTHON3" || die "python3 not found"
    have "$CODESIGN" || die "codesign not found"
    [[ -x "$SIGN_UPDATE" ]] || die "$SIGN_UPDATE is missing or not executable"
    for name in "$MAKE_UPDATE_ARCHIVE" "$MAKE_APPCAST"; do
        [[ -x "$name" ]] || die "$name is missing or not executable"
    done
    BUILD1="$(build_number_for "$VERSION1")"
    BUILD2="$(build_number_for "$VERSION2")"
    CHECK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/rfm-rehearsal-check.XXXXXX")"
    trap 'rm -rf "$CHECK_TMP"' EXIT

    for spec in "build1 $VERSION1 $BUILD1 NO" "build2 $VERSION2 $BUILD2 NO" "build1-nocleanup $VERSION1 $BUILD1 YES"; do
        read -r name version build skip <<< "$spec"
        check_app "$name" "$version" "$build" "$skip"
        drs="$drs$APP_DR$NL"
    done
    first="${drs%%"$NL"*}"
    if [[ -n "$first" && "$drs" == "$first$NL$first$NL$first$NL" ]]; then
        pass "V1: build1, build2 and build1-nocleanup share one designated requirement"
    else
        fail "V1: the three builds do not share one designated requirement, so an update would not keep its grants"
    fi
    check_good_feed
    check_bad_feed
    check_two_releases

    if [[ "$FAILURES" -eq 0 ]]; then
        say "all $CHECKS checks passed"
    else
        printf 'error: %d of %d checks failed\n' "$FAILURES" "$CHECKS"
        exit 1
    fi
}

# ------------------------------------------------------------------ serve

cmd_serve() {
    local workdir="" bad=0 port="" directory built
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --bad)
                bad=1
                shift
                ;;
            --port)
                need_value "$@"
                port="$2"
                shift 2
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            -*) usage_error "unknown argument: $1" ;;
            *)
                [[ -z "$workdir" ]] || usage_error "unexpected argument: $1"
                workdir="$1"
                shift
                ;;
        esac
    done
    [[ -n "$workdir" ]] || usage_error "serve needs a <workdir>"
    WORK="$(physical_path "$workdir")"
    require_prepared
    built="$(state_value PORT)"
    port="${port:-$built}"
    valid_port "$port" || usage_error "--port must be a number from 1024 to 65535"
    directory="$WORK/feed"
    if [[ "$bad" -eq 1 ]]; then
        directory="$WORK/feed-bad"
    fi
    [[ -d "$directory" ]] || die "$directory does not exist"
    have "$PYTHON3" || die "python3 not found"
    if [[ "$port" != "$built" ]]; then
        warn "the builds in $WORK ask for http://127.0.0.1:$built/appcast.xml; port $port will not be reached by them"
    fi
    say "serving $directory on http://127.0.0.1:$port/ (Ctrl-C stops it; every request is logged below)"
    exec "$PYTHON3" -m http.server "$port" --bind 127.0.0.1 --directory "$directory"
}

main() {
    if [[ $# -eq 0 ]]; then
        usage_error "missing command: prepare, check or serve"
    fi
    local command="$1"
    shift
    case "$command" in
        -h | --help | help)
            usage
            exit 0
            ;;
        prepare) cmd_prepare "$@" ;;
        check) cmd_check "$@" ;;
        serve) cmd_serve "$@" ;;
        *) usage_error "unknown command: $command" ;;
    esac
}

main "$@"
