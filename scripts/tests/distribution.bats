#!/usr/bin/env bats
# Pins RoomForMac's distribution identifiers and checks the two libraries that
# read them (Plan 6, Task 1). Text checks only: no build, keychain or network.
#
#   - the identifiers fixed for life: changing one takes a deliberate edit of
#     this file (Plan 6, Global Constraints);
#   - how project.yml, Config/App.xcconfig and Config/Distribution.xcconfig fit
#     together;
#   - scripts/lib/distribution.sh (distribution_value), which is run against
#     fixture files in $BATS_TEST_TMPDIR, never against the real one;
#   - scripts/lib/version.sh (version_is_release, build_number_for).
#
# Later tasks append their own pins to this file: the Sparkle pin (Task 3), the
# import rule (Task 5) and the icon stamp (Task 7).

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export ROOT
}

# Sourced by the tests that need them, not by setup(), so that a missing
# library fails only those tests.
use_libs() {
    source "$ROOT/scripts/lib/distribution.sh"
    source "$ROOT/scripts/lib/version.sh"
}

# yaml_value FILE KEY...: prints the value at that path of a YAML file (an
# integer KEY indexes a list). YAML 1.1 reads an unquoted NO or YES as a
# boolean, so those print as false and true. A missing key is an error.
yaml_value() {
    local file="$1"
    shift
    ruby -ryaml -e '
        node = YAML.load_file(ARGV.shift)
        ARGV.each { |key| node = node.fetch(key =~ /\A\d+\z/ ? key.to_i : key) }
        puts node' "$file" "$@"
}

# yaml_keys FILE KEY...: the sorted keys of the mapping at that path.
yaml_keys() {
    local file="$1"
    shift
    ruby -ryaml -e '
        node = YAML.load_file(ARGV.shift)
        ARGV.each { |key| node = node.fetch(key =~ /\A\d+\z/ ? key.to_i : key) }
        puts node.keys.sort' "$file" "$@"
}

# fixture_root LINE...: writes the lines to Config/Distribution.xcconfig of a
# scratch root and prints that root.
fixture_root() {
    local root="$BATS_TEST_TMPDIR/root"
    mkdir -p "$root/Config"
    printf '%s\n' "$@" > "$root/Config/Distribution.xcconfig"
    printf '%s\n' "$root"
}

# bare_slashes FILE: prints every line of an xcconfig file that Xcode would cut
# short: a "//" that is not in a comment line and not in a trailing comment (a
# whitespace, then "//"). It exits 0 when it found none, and 1 for a missing file.
bare_slashes() {
    local found
    if [ ! -f "$1" ]; then
        echo "no such file: $1" >&2
        return 1
    fi
    found="$(sed -e '/^[[:space:]]*\/\//d' -e 's#[[:space:]]//.*$##' "$1" | grep -n '//' || true)"
    if [ -n "$found" ]; then
        printf '%s\n' "$found"
        return 1
    fi
}

# conditional_names FILE: prints every line of an xcconfig file whose setting name
# has a "[" (a conditional name such as RFM_A[config=Release]) or a "$" (a name
# built from another setting) before the "=". Xcode applies those, and
# distribution_value cannot see them: it would answer with the unconditional
# value while a Release build uses the other one. It exits 0 when it found none,
# and 1 for a missing file.
conditional_names() {
    local found
    if [ ! -f "$1" ]; then
        echo "no such file: $1" >&2
        return 1
    fi
    found="$(grep -n -E '^[[:space:]]*[^/#=]*[[$]' "$1" || true)"
    if [ -n "$found" ]; then
        printf '%s\n' "$found"
        return 1
    fi
}

# fingerprint_file_ok FILE: 0 when FILE is exactly 40 hex digits and a newline.
fingerprint_file_ok() {
    local first40
    first40="$(head -c 40 "$1")"
    [[ "$first40" =~ ^[0-9A-Fa-f]{40}$ ]] && printf '%s\n' "$first40" | cmp -s - "$1"
}

# --- the identifiers fixed for life ------------------------------------------

@test "the bundle ID and the URL scheme are the ones fixed for life" {
    local yml="$ROOT/project.yml"
    [ "$(yaml_value "$yml" targets RoomForMac settings base PRODUCT_BUNDLE_IDENTIFIER)" = "com.roomformac.RoomForMac" ]
    [ "$(yaml_value "$yml" targets RoomForMac info properties CFBundleURLTypes 0 CFBundleURLName)" = "com.roomformac.RoomForMac" ]
    # exactly one scheme: puts prints one line per list entry
    [ "$(yaml_value "$yml" targets RoomForMac info properties CFBundleURLTypes 0 CFBundleURLSchemes)" = "roomformac" ]
}

@test "the feed, repository, site and volume name are the ones fixed for life" {
    use_libs
    [ "$(distribution_value "$ROOT" RFM_REPOSITORY)" = "gugag2003/RoomForMac" ]
    [ "$(distribution_value "$ROOT" RFM_FEED_URL)" = "https://github.com/gugag2003/RoomForMac/releases/latest/download/appcast.xml" ]
    [ "$(distribution_value "$ROOT" RFM_SITE_URL)" = "https://gugag2003.github.io/RoomForMac" ]
    [ "$(distribution_value "$ROOT" RFM_DMG_VOLUME_NAME)" = "RoomForMac" ]
}

@test "the feed is a release asset of the repository named in the same file" {
    use_libs
    local repository feed
    repository="$(distribution_value "$ROOT" RFM_REPOSITORY)"
    feed="$(distribution_value "$ROOT" RFM_FEED_URL)"
    [ "$feed" = "https://github.com/$repository/releases/latest/download/appcast.xml" ]
}

@test "the public key is empty or 44 characters of base64 for 32 bytes" {
    use_libs
    local key shape='^[A-Za-z0-9+/]{43}=$'
    key="$(distribution_value "$ROOT" RFM_SPARKLE_PUBLIC_KEY)"
    [[ -z "$key" || "$key" =~ $shape ]]
}

@test "the bare-slash check finds what Xcode would cut, and only that" {
    local file="$BATS_TEST_TMPDIR/probe.xcconfig"
    printf '%s\n' '// https://a comment may contain slashes' 'A = https:/$()/ok // and so may this' \
        'B = fine' > "$file"
    bare_slashes "$file"
    printf '%s\n' 'A = https://cut.example' > "$file"
    run bare_slashes "$file"
    [ "$status" -eq 1 ]
    [ "$output" = "1:A = https://cut.example" ]
    printf '%s\n' 'A = value// glued comment' > "$file"
    run bare_slashes "$file"
    [ "$status" -eq 1 ]
}

@test "Distribution.xcconfig writes every URL the way Xcode reads it" {
    run bare_slashes "$ROOT/Config/Distribution.xcconfig"
    [ "$status" -eq 0 ]
}

@test "the conditional-name check finds what distribution_value cannot see, and only that" {
    local file="$BATS_TEST_TMPDIR/probe.xcconfig"
    printf '%s\n' '// RFM_A[config=Release] = a comment may name a condition' \
        'RFM_A = a[b] $(X) // RFM_A[sdk=macosx*] = 2' '#include? "Local[1].xcconfig"' \
        'RFM_B = https:/$()/fine' > "$file"
    conditional_names "$file"
    printf '%s\n' 'RFM_A = 1' 'RFM_A[config=Release] = 2' > "$file"
    run conditional_names "$file"
    [ "$status" -eq 1 ]
    [ "$output" = "2:RFM_A[config=Release] = 2" ]
    printf '%s\n' '  RFM_A [sdk=macosx*] = 2' > "$file"
    run conditional_names "$file"
    [ "$status" -eq 1 ]
    printf '%s\n' 'RFM_A$(SUFFIX) = 2' > "$file"
    run conditional_names "$file"
    [ "$status" -eq 1 ]
}

@test "Distribution.xcconfig has no conditional or computed setting names" {
    run conditional_names "$ROOT/Config/Distribution.xcconfig"
    [ "$status" -eq 0 ]
}

# --- how the configuration files fit together --------------------------------

@test "App.xcconfig includes Distribution.xcconfig, then Signing.xcconfig, and sets nothing itself" {
    local settings
    settings="$(grep -v -e '^[[:space:]]*//' -e '^[[:space:]]*$' "$ROOT/Config/App.xcconfig")"
    [ "$settings" = $'#include "Distribution.xcconfig"\n#include "Signing.xcconfig"' ]
}

@test "Signing.xcconfig still ends with the per-developer include" {
    [ "$(tail -n 1 "$ROOT/Config/Signing.xcconfig")" = '#include? "Local.xcconfig"' ]
}

@test "App.xcconfig, Distribution.xcconfig and project.yml carry no signing settings" {
    local file
    for file in Config/App.xcconfig Config/Distribution.xcconfig project.yml; do
        [ -f "$ROOT/$file" ]
        if grep -n -E 'CODE_SIGN_|DEVELOPMENT_TEAM|ENABLE_HARDENED_RUNTIME' "$ROOT/$file" >&2; then
            echo "$file mentions a signing setting; they live only in Config/Signing.xcconfig" >&2
            return 1
        fi
    done
}

@test "project.yml points Debug and Release at Config/App.xcconfig" {
    [ "$(yaml_value "$ROOT/project.yml" configFiles Debug)" = "Config/App.xcconfig" ]
    [ "$(yaml_value "$ROOT/project.yml" configFiles Release)" = "Config/App.xcconfig" ]
}

@test "project.yml compiles the distribution values into Info.plist" {
    local properties=(targets RoomForMac info properties)
    local yml="$ROOT/project.yml"
    [ "$(yaml_value "$yml" "${properties[@]}" SUFeedURL)" = '$(RFM_FEED_URL)' ]
    [ "$(yaml_value "$yml" "${properties[@]}" SUPublicEDKey)" = '$(RFM_SPARKLE_PUBLIC_KEY)' ]
    [ "$(yaml_value "$yml" "${properties[@]}" SUEnableAutomaticChecks)" = "true" ]
    [ "$(yaml_value "$yml" "${properties[@]}" RFMSiteURL)" = '$(RFM_SITE_URL)' ]
    [ "$(yaml_value "$yml" "${properties[@]}" RFMSkipQuarantineCleanup)" = '$(RFM_SKIP_QUARANTINE_CLEANUP)' ]
}

@test "project.yml sets no Sparkle key besides the three it needs" {
    local keys
    keys="$(yaml_keys "$ROOT/project.yml" targets RoomForMac info properties | grep '^SU')"
    [ "$keys" = $'SUEnableAutomaticChecks\nSUFeedURL\nSUPublicEDKey' ]
}

@test "the quarantine-cleanup opt-out defaults to NO" {
    local value
    value="$(yaml_value "$ROOT/project.yml" settings base RFM_SKIP_QUARANTINE_CLEANUP)"
    # YAML 1.1 reads an unquoted NO as false; XcodeGen writes it out as NO.
    [ "$value" = "false" ] || [ "$value" = "NO" ]
}

# --- scripts/lib/distribution.sh ---------------------------------------------

@test "distribution_value reads the empty-expansion trick, comments and spacing" {
    use_libs
    local root
    root="$(fixture_root \
        '// a comment about RFM_FEED_URL = https://never.example' \
        '' \
        '   RFM_FEED_URL   =   https:/$()/example.test/a/b.xml   ' \
        $'RFM_TABBED\t=\tvalue\t' \
        'RFM_COMMENTED = kept // this trailing comment goes' \
        'RFM_KEY = AAAA/$()/BBBB+CCCC==' \
        'RFM_SPLIT = a$()b$()c' \
        'RFM_EMPTY_THEN_COMMENT = // nothing before the comment' \
        '#include? "Local.xcconfig"')"
    [ "$(distribution_value "$root" RFM_FEED_URL)" = "https://example.test/a/b.xml" ]
    [ "$(distribution_value "$root" RFM_TABBED)" = "value" ]
    [ "$(distribution_value "$root" RFM_COMMENTED)" = "kept" ]
    [ "$(distribution_value "$root" RFM_KEY)" = "AAAA//BBBB+CCCC==" ]
    [ "$(distribution_value "$root" RFM_SPLIT)" = "abc" ]
    [ -z "$(distribution_value "$root" RFM_EMPTY_THEN_COMMENT)" ]
}

@test "distribution_value prints an empty value as one empty line and succeeds" {
    use_libs
    local root
    root="$(fixture_root 'RFM_SPARKLE_PUBLIC_KEY =')"
    run distribution_value "$root" RFM_SPARKLE_PUBLIC_KEY
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(distribution_value "$root" RFM_SPARKLE_PUBLIC_KEY | wc -c | tr -d ' ')" = "1" ]
}

@test "distribution_value reads a last line that has no newline" {
    use_libs
    local root="$BATS_TEST_TMPDIR/root"
    mkdir -p "$root/Config"
    printf 'RFM_FIRST = 1\nRFM_LAST = 2' > "$root/Config/Distribution.xcconfig"
    [ "$(distribution_value "$root" RFM_LAST)" = "2" ]
}

@test "distribution_value never evaluates what it reads" {
    use_libs
    local root marker="$BATS_TEST_TMPDIR/evaluated"
    root="$(fixture_root \
        "RFM_SUBSTITUTION = \$(touch $marker)" \
        "RFM_BACKTICKS = \`touch $marker\`" \
        'RFM_VARIABLES = $HOME ${HOME} $(HOME)')"
    [ "$(distribution_value "$root" RFM_SUBSTITUTION)" = "\$(touch $marker)" ]
    [ "$(distribution_value "$root" RFM_BACKTICKS)" = "\`touch $marker\`" ]
    [ "$(distribution_value "$root" RFM_VARIABLES)" = '$HOME ${HOME} $(HOME)' ]
    [ ! -e "$marker" ]
}

@test "distribution_value matches whole key names only" {
    use_libs
    local root
    root="$(fixture_root 'RFM_FEED_URL_OLD = old' 'XRFM_FEED_URL = other' 'RFM_FEED_URL = new')"
    [ "$(distribution_value "$root" RFM_FEED_URL)" = "new" ]
    run distribution_value "$root" RFM_FEED
    [ "$status" -eq 1 ]
}

@test "distribution_value fails on a key that is not defined, and names it" {
    use_libs
    local root
    root="$(fixture_root 'RFM_A = 1' '// RFM_MISSING = commented out')"
    run distribution_value "$root" RFM_MISSING
    [ "$status" -eq 1 ]
    [[ "$output" == "error: RFM_MISSING is not defined in "* ]]
}

@test "distribution_value fails on a key defined twice, even with equal values" {
    use_libs
    local root
    root="$(fixture_root 'RFM_A = 1' 'RFM_B = 2' 'RFM_A = 1')"
    run distribution_value "$root" RFM_A
    [ "$status" -eq 1 ]
    [[ "$output" == "error: RFM_A is defined more than once in "* ]] || return 1
    [ "$(distribution_value "$root" RFM_B)" = "2" ]
}

@test "distribution_value does not count a commented-out definition as a second one" {
    use_libs
    local root
    root="$(fixture_root '// RFM_A = 0' 'RFM_A = 1 // was RFM_A = 0')"
    [ "$(distribution_value "$root" RFM_A)" = "1" ]
}

@test "distribution_value fails without the file or without both arguments" {
    use_libs
    run distribution_value "$BATS_TEST_TMPDIR/no-such-root" RFM_A
    [ "$status" -eq 1 ]
    [[ "$output" == "error: "*"Config/Distribution.xcconfig does not exist" ]] || return 1
    run distribution_value "$BATS_TEST_TMPDIR"
    [ "$status" -eq 1 ]
    [ "$output" = "error: usage: distribution_value ROOT KEY" ]
    run distribution_value
    [ "$status" -eq 1 ]
}

# --- scripts/lib/version.sh --------------------------------------------------

@test "build_number_for gives X*1000000 + Y*1000 + Z" {
    use_libs
    local pair version expected
    for pair in 0.0.1:1 0.1.0:1000 0.1.1:1001 1.0.0:1000000 1.2.3:1002003 \
        10.20.30:10020030 1.999.999:1999999 2000.999.999:2000999999; do
        version="${pair%%:*}"
        expected="${pair##*:}"
        [ "$(build_number_for "$version")" = "$expected" ]
    done
}

@test "the largest build number still fits in 32 bits" {
    use_libs
    [ "$(build_number_for 2000.999.999)" -lt 2147483647 ]
}

@test "build_number_for and version_is_release refuse everything but a strict release version" {
    use_libs
    local version
    for version in 2001.0.0 01.2.3 1.02.3 1.2.03 1.2 1 1.2.3.4 1.2.3-beta 1.2.3+5 v1.2.3 V1.2.3 \
        1.1000.0 1.0.1000 -1.2.3 1.-2.3 1..3 .1.2 1.2. a.b.c 1.2.x '' ' ' ' 1.2.3' '1.2.3 ' \
        $'1.2.3\n' $'1.2.3\n4' 99999999999999999999.0.0 1.99999999999999999999.0; do
        if out="$(build_number_for "$version" 2> /dev/null)"; then
            echo "build_number_for accepted [$version] as $out" >&2
            return 1
        fi
        if version_is_release "$version"; then
            echo "version_is_release accepted [$version]" >&2
            return 1
        fi
    done
}

@test "build_number_for explains a refusal on stderr and prints nothing on stdout" {
    use_libs
    local out err
    out="$(build_number_for v1.2.3 2> "$BATS_TEST_TMPDIR/err" || true)"
    err="$(cat "$BATS_TEST_TMPDIR/err")"
    [ -z "$out" ]
    [[ "$err" == "error: not a release version "*": v1.2.3" ]]
}

@test "version_is_release accepts the strict versions and prints nothing" {
    use_libs
    local version
    for version in 0.0.1 0.1.0 1.0.0 1.2.3 10.20.30 999.999.999 2000.0.0 2000.999.999; do
        run version_is_release "$version"
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    done
}

@test "build numbers grow strictly along sort -V, so every release outranks the ones before it" {
    use_libs
    local version number previous=-1
    while IFS= read -r version; do
        number="$(build_number_for "$version")"
        if [ "$number" -le "$previous" ]; then
            echo "$version gives $number, which is not above $previous" >&2
            return 1
        fi
        previous="$number"
    done < <(printf '%s\n' 1.10.0 0.100.0 1.0.10 0.99.99 2.0.0 0.10.1 1.0.100 0.1.0 1.999.999 \
        0.9.9 0.0.1 1.1.0 10.0.0 0.10.0 1.0.1 1.2.3 100.0.0 1.0.0 0.2.0 0.1.1 2000.999.999 | sort -V)
    [ "$previous" -eq 2000999999 ]
}

@test "version_is_release leaves no variable behind under zsh either" {
    command -v zsh > /dev/null || skip "zsh is not installed"
    run zsh -c '
        source "$1/scripts/lib/version.sh"
        version_is_release 1.2.3 || echo "1.2.3 refused"
        version_is_release 2001.0.0 && echo "2001.0.0 accepted"
        build_number_for 1.2.3
        for name in MATCH MBEGIN MEND match mbegin mend; do
            [[ -n ${(P)name+set} ]] && echo "leaked $name"
        done
        echo done' _ "$ROOT"
    [ "$status" -eq 0 ]
    [ "$output" = $'1002003\ndone' ]
}

# --- both libraries ----------------------------------------------------------

@test "sourcing the libraries defines functions only" {
    run /bin/bash -c '
        (set +o; shopt -p; compgen -v | sort) > "$2/before"
        source "$1/scripts/lib/distribution.sh"
        source "$1/scripts/lib/version.sh"
        (set +o; shopt -p; compgen -v | sort) > "$2/after"
        cmp "$2/before" "$2/after"' _ "$ROOT" "$BATS_TEST_TMPDIR"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "a failing call returns to its caller instead of ending the shell" {
    run /bin/bash -c '
        source "$1/scripts/lib/distribution.sh"
        source "$1/scripts/lib/version.sh"
        distribution_value "$1" RFM_NO_SUCH_KEY 2> /dev/null || echo "distribution_value: $?"
        build_number_for 1.2 2> /dev/null || echo "build_number_for: $?"
        version_is_release 1.2 || echo "version_is_release: $?"
        echo done' _ "$ROOT"
    [ "$status" -eq 0 ]
    [ "$output" = $'distribution_value: 1\nbuild_number_for: 1\nversion_is_release: 1\ndone' ]
}

# --- Config/signing-identity.sha1 --------------------------------------------

@test "the fingerprint check accepts 40 hex digits and a newline, and nothing else" {
    local file="$BATS_TEST_TMPDIR/sha1" hex="0123456789ABCDEF0123456789abcdef01234567"
    printf '%s\n' "$hex" > "$file"
    fingerprint_file_ok "$file"
    printf '%s\n' "${hex//[A-F]/a}" > "$file"
    fingerprint_file_ok "$file"
    local bad
    for bad in "${hex%?}"$'\n' "${hex}0"$'\n' "$hex" "$hex"$'\r\n' "$hex"$'\n\n' "$hex"$'\nx\n' \
        $'\n'"$hex" "${hex%?}g"$'\n' "H\"$hex\""$'\n' "$hex \"RoomForMac Self-Signed\""$'\n' ''; do
        printf '%s' "$bad" > "$file"
        if fingerprint_file_ok "$file"; then
            echo "accepted: $(od -c "$file" | head -n 3)" >&2
            return 1
        fi
    done
}

@test "Config/signing-identity.sha1, when present, is 40 hex digits and a newline" {
    [ -f "$ROOT/Config/signing-identity.sha1" ] || skip "the owner commits Config/signing-identity.sha1 (owner step A3)"
    fingerprint_file_ok "$ROOT/Config/signing-identity.sha1"
}

# SHA-256 of ThirdParty/Sparkle/LICENSE at tag 2.10.0 of the Sparkle repository (Task 3, Step 1).
SPARKLE_LICENSE_SHA256=389a4e4e9a32f059775b13a06e25a591445ba229d2838d26dd3e7c0c45127cfe

# --- Sparkle (Plan 6, Task 3) -----------------------------------------------

@test "ThirdParty/Sparkle/LICENSE is the file at Sparkle's tag 2.10.0" {
    local actual
    actual="$(shasum -a 256 "$ROOT/ThirdParty/Sparkle/LICENSE" | cut -d' ' -f1)"
    [ "$actual" = "$SPARKLE_LICENSE_SHA256" ]
}

@test "project.yml pins Sparkle exactly, and only the app target links it" {
    run ruby -ryaml -e '
        spec = YAML.load_file(ARGV[0])
        sparkle = spec.fetch("packages").fetch("Sparkle")
        expected = { "url" => "https://github.com/sparkle-project/Sparkle", "exactVersion" => ARGV[1] }
        abort "wrong Sparkle package: #{sparkle.inspect}" unless sparkle == expected
        targets = spec.fetch("targets")
        packages = ->(name) { targets.fetch(name).fetch("dependencies", []).map { |d| d["package"] }.compact }
        abort "the app must link Sparkle" unless packages.call("RoomForMac").include?("Sparkle")
        %w[RoomForMacTests RoomForMacUITests].each do |name|
            abort "#{name} must not link Sparkle" if packages.call(name).include?("Sparkle")
        end
        link = targets.fetch("RoomForMac").fetch("dependencies").find { |d| d["package"] == "Sparkle" }
        abort "the product must be Sparkle: #{link.inspect}" unless link["product"] == "Sparkle"
        abort "Sparkle must not set embed: Xcode embeds it itself: #{link.inspect}" if link.key?("embed")
    ' "$ROOT/project.yml" "$(source "$ROOT/scripts/lib/sparkle.sh" && echo "$SPARKLE_VERSION")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "project.yml runs Prepare Sparkle after Embed engine and bundles ThirdParty as a resource folder" {
    run ruby -ryaml -e '
        app = YAML.load_file(ARGV[0]).fetch("targets").fetch("RoomForMac")
        phases = app.fetch("postBuildScripts")
        names = phases.map { |p| p["name"] }
        abort "phases: #{names.inspect}" unless names.include?("Embed engine") && names.include?("Prepare Sparkle")
        abort "Prepare Sparkle must run after Embed engine" unless names.index("Prepare Sparkle") > names.index("Embed engine")
        phase = phases.find { |p| p["name"] == "Prepare Sparkle" }
        abort "wrong script: #{phase["script"]}" unless phase["script"] == %q("${SRCROOT}/scripts/prepare-sparkle.sh")
        abort "the phase must run on every build" unless phase["basedOnDependencyAnalysis"] == false
        framework = "$(TARGET_BUILD_DIR)/$(FRAMEWORKS_FOLDER_PATH)/Sparkle.framework/Versions/B"
        inputs = ["#{framework}/Sparkle", "#{framework}/_CodeSignature"]
        abort "the phase must wait for Xcode to copy and sign Sparkle.framework: #{phase["inputFiles"].inspect}" unless phase["inputFiles"] == inputs
        folder = app.fetch("sources").find { |s| s.is_a?(Hash) && s["path"] == "ThirdParty" }
        expected = { "path" => "ThirdParty", "type" => "folder", "buildPhase" => "resources" }
        abort "ThirdParty entry: #{folder.inspect}" unless folder == expected
    ' "$ROOT/project.yml"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "NOTICE and CREDITS.md name Sparkle at the pinned version and point to its license" {
    local version
    version="$(source "$ROOT/scripts/lib/sparkle.sh" && echo "$SPARKLE_VERSION")"
    grep -qx 'Software updates' "$ROOT/NOTICE"
    grep -q 'https://sparkle-project.org' "$ROOT/NOTICE"
    grep -q 'ThirdParty/Sparkle/LICENSE' "$ROOT/NOTICE"
    grep -qx '## Software updates' "$ROOT/CREDITS.md"
    grep -q "^- Sparkle $version, MIT, https://sparkle-project.org\$" "$ROOT/CREDITS.md"
}

@test "the String Catalog has the title of Sparkle's license in About" {
    run python3 -c '
import json
import sys

strings = json.load(open(sys.argv[1]))["strings"]
sys.exit(0 if "Updates License (Sparkle)" in strings else 1)
' "$ROOT/RoomForMac/Resources/Localizable.xcstrings"
    [ "$status" -eq 0 ]
}

@test "Release turns the hardened runtime on and injects no base entitlements" {
    run grep -Fx 'ENABLE_HARDENED_RUNTIME[config=Release] = YES' "$ROOT/Config/Signing.xcconfig"
    [ "$status" -eq 0 ]
    run grep -Fx 'CODE_SIGN_INJECT_BASE_ENTITLEMENTS[config=Release] = NO' "$ROOT/Config/Signing.xcconfig"
    [ "$status" -eq 0 ]
}
