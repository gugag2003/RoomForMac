#!/usr/bin/env bats
# Checks scripts/stage-site.sh and the pages under site/. The script runs on the
# real site into a test folder, or on a copy of what it reads (a "fixture") that a
# test breaks on purpose. Nothing here needs a browser, the network or a prompt:
# the two page functions run through `osascript -l JavaScript`, which is
# JavaScriptCore alone, with no Apple event.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
    TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
    OUT="$TMP/out"
    SCRIPT="$REPO/scripts/stage-site.sh"
    SHA_256="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    # shellcheck source=../lib/distribution.sh
    source "$REPO/scripts/lib/distribution.sh"
    REPOSITORY="$(distribution_value "$REPO" RFM_REPOSITORY)"
    SITE_URL="$(distribution_value "$REPO" RFM_SITE_URL)"
    FEED_URL="$(distribution_value "$REPO" RFM_FEED_URL)"
    DMG_URL="https://github.com/$REPOSITORY/releases/latest/download/RoomForMac.dmg"
}

# A copy of what stage-site.sh reads, so a test can break it. The script finds
# its root from its own path, so the copy stages the copy.
make_fixture() {
    FIXTURE="$TMP/fixture"
    mkdir -p "$FIXTURE/scripts/lib" "$FIXTURE/Config"
    cp "$REPO/scripts/stage-site.sh" "$FIXTURE/scripts/"
    cp "$REPO/scripts/lib/distribution.sh" "$FIXTURE/scripts/lib/"
    cp "$REPO/Config/Distribution.xcconfig" "$FIXTURE/Config/"
    cp -R "$REPO/site" "$FIXTURE/site"
}

# A release summary as Task 11's release-summary.sh writes it. $1 is the version.
write_summary() {
    printf '{"schema":1,"version":"%s","build":1000,"minimum_macos":"26.0","date":"2026-09-29","dmg":{"url":"https://github.com/%s/releases/download/v%s/RoomForMac.dmg","size":11840000,"sha256":"%s"}}\n' \
        "$1" "$REPOSITORY" "$1" "$SHA_256" > "$TMP/latest.json"
}

# Stages the real site into $OUT.
stage_real() {
    run "$SCRIPT" "$OUT"
    [ "$status" -eq 0 ]
}

# Every staged text file the browser would load.
staged_text_files() {
    find "$OUT" -type f \( -name '*.html' -o -name '*.js' -o -name '*.css' \)
}

# Calls roomForMacDeepLink once per argument and prints one line per call:
# the link, or "null". "@undefined" stands for no argument at all.
deep_links() {
    command -v osascript > /dev/null 2>&1 || skip "osascript is not available"
    {
        cat "$REPO/site/assets/thanks.js"
        cat << 'JS'
function run(argv) {
    var lines = [];
    for (var i = 0; i < argv.length; i++) {
        var result = roomForMacDeepLink(argv[i] === '@undefined' ? undefined : argv[i]);
        lines.push(result === null ? 'null' : result);
    }
    return lines.join('\n');
}
JS
    } > "$TMP/deep-link-driver.js"
    run osascript -l JavaScript "$TMP/deep-link-driver.js" "$@"
}

# Calls roomForMacDownloadDetails once per JSON argument and prints one line per
# call: the details as JSON, or "null".
download_details() {
    command -v osascript > /dev/null 2>&1 || skip "osascript is not available"
    {
        cat "$REPO/site/assets/download.js"
        cat << 'JS'
function run(argv) {
    var lines = [];
    for (var i = 0; i < argv.length; i++) {
        var summary = null;
        try {
            summary = JSON.parse(argv[i]);
        } catch (error) {
            summary = null;
        }
        var result = roomForMacDownloadDetails(summary);
        lines.push(result === null ? 'null' : JSON.stringify(result));
    }
    return lines.join('\n');
}
JS
    } > "$TMP/download-driver.js"
    run osascript -l JavaScript "$TMP/download-driver.js" "$@"
}

@test "--help prints the usage and exits 0" {
    run "$SCRIPT" --help
    [ "$status" -eq 0 ]
    [[ "$output" == "Usage: scripts/stage-site.sh <out-dir> [latest.json] [--strict | --strict-from-summary]"* ]] || return 1
    [ ! -e "$OUT" ]
}

@test "bad usage exits 2 and stages nothing" {
    run "$SCRIPT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: an output folder is required"* ]] || return 1
    run "$SCRIPT" "$OUT" --nope
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: unknown argument: --nope"* ]] || return 1
    run "$SCRIPT" "$OUT" latest.json extra.json
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: unexpected argument: extra.json"* ]] || return 1
    run "$SCRIPT" "$OUT" --strict-from-summary
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: --strict-from-summary needs a latest.json"* ]] || return 1
    [ ! -e "$OUT" ]
}

@test "a folder that has files, or that is inside site/, is refused" {
    mkdir -p "$OUT"
    printf 'keep\n' > "$OUT/keep.txt"
    run "$SCRIPT" "$OUT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"is not empty; remove it first"* ]] || return 1
    [ "$(cat "$OUT/keep.txt")" = "keep" ]
    [ "$(ls "$OUT")" = "keep.txt" ]
    run "$SCRIPT" "$REPO/site/staged"
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: the output folder must not be inside site/"* ]] || return 1
    [ ! -e "$REPO/site/staged" ]
}

@test "it stages every page, fills every token and inserts the repository and DMG URLs" {
    local page
    stage_real
    for page in index.html open-anyway/index.html thanks/index.html privacy/index.html 404.html \
        assets/site.css assets/download.js assets/thanks.js; do
        [ -s "$OUT/$page" ]
    done
    run grep -rIl '@RFM_' "$OUT"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    grep -qF "<a class=\"button\" href=\"$DMG_URL\">Download for Mac</a>" "$OUT/index.html"
    grep -qF "href=\"https://github.com/$REPOSITORY\"" "$OUT/index.html"
    grep -qF "href=\"$SITE_URL/open-anyway/\"" "$OUT/404.html"
    grep -qF "<code>$FEED_URL</code>" "$OUT/privacy/index.html"
}

@test "a token is replaced with the configured value, not a fixed one" {
    make_fixture
    sed -e 's|^RFM_REPOSITORY = .*|RFM_REPOSITORY = example/Other-Repo|' \
        -e 's|^RFM_SITE_URL = .*|RFM_SITE_URL = https:/$()/example.test/base/|' \
        -e 's|^RFM_FEED_URL = .*|RFM_FEED_URL = https:/$()/example.test/feed.xml|' \
        "$REPO/Config/Distribution.xcconfig" > "$FIXTURE/Config/Distribution.xcconfig"
    run "$FIXTURE/scripts/stage-site.sh" "$OUT"
    [ "$status" -eq 0 ]
    grep -qF 'href="https://github.com/example/Other-Repo/releases/latest/download/RoomForMac.dmg"' "$OUT/index.html"
    grep -qF 'href="https://example.test/base/privacy/"' "$OUT/404.html"
    grep -qF '<code>https://example.test/feed.xml</code>' "$OUT/privacy/index.html"
    run grep -rIl 'gugag2003' "$OUT"
    [ "$status" -eq 1 ]
}

@test "a value that could break out of an attribute is refused" {
    make_fixture
    sed -e 's|^RFM_REPOSITORY = .*|RFM_REPOSITORY = a"b/c|' "$REPO/Config/Distribution.xcconfig" > "$FIXTURE/Config/Distribution.xcconfig"
    run "$FIXTURE/scripts/stage-site.sh" "$OUT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"error: RFM_REPOSITORY must look like owner/name"* ]] || return 1
    [ ! -e "$OUT" ]
}

@test "the appcast is never part of the site, and latest.json only when given" {
    stage_real
    [ ! -e "$OUT/appcast.xml" ]
    [ ! -e "$OUT/latest.json" ]
    make_fixture
    printf '<rss/>\n' > "$FIXTURE/site/appcast.xml"
    run "$FIXTURE/scripts/stage-site.sh" "$TMP/out2"
    [ "$status" -eq 1 ]
    [[ "$output" == *"site/appcast.xml must not exist"* ]] || return 1
    [ ! -e "$TMP/out2" ]
}

@test "latest.json is copied unchanged when it is a release summary" {
    write_summary 0.1.0
    run "$SCRIPT" "$OUT" "$TMP/latest.json"
    [ "$status" -eq 0 ]
    cmp "$TMP/latest.json" "$OUT/latest.json"
}

@test "a file that is not a release summary is refused and nothing is staged" {
    printf '{"schema":2,"version":"0.1.0"}\n' > "$TMP/latest.json"
    run "$SCRIPT" "$OUT" "$TMP/latest.json"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not a release summary: schema 1 is missing"* ]] || return 1
    [[ "$output" == *"is not a release summary: no SHA-256"* ]] || return 1
    [ ! -e "$OUT" ]
    run "$SCRIPT" "$OUT" "$TMP/missing.json"
    [ "$status" -eq 1 ]
    [[ "$output" == *"latest.json not found: $TMP/missing.json"* ]] || return 1
    [ ! -e "$OUT" ]
}

@test "--strict fails on an OWNER placeholder, names the page and stages nothing" {
    run "$SCRIPT" "$OUT" --strict
    [ "$status" -eq 1 ]
    [[ "$output" == *"error: --strict: a placeholder is left in privacy/index.html"* ]] || return 1
    [ ! -e "$OUT" ]
}

@test "--strict passes once the placeholders are filled in" {
    make_fixture
    sed 's/\[OWNER: [^]]*\]/Example Ltd/g' "$REPO/site/privacy/index.html" > "$FIXTURE/site/privacy/index.html"
    run grep -c 'OWNER:' "$FIXTURE/site/privacy/index.html"
    [ "$output" = "0" ]
    run "$FIXTURE/scripts/stage-site.sh" "$OUT" --strict
    [ "$status" -eq 0 ]
}

@test "--strict-from-summary is strict from 1.0.0 on, and not before" {
    local version
    for version in 0.1.0 0.9.9 0.12.0; do
        write_summary "$version"
        rm -rf "$OUT"
        run "$SCRIPT" "$OUT" "$TMP/latest.json" --strict-from-summary
        [ "$status" -eq 0 ]
    done
    for version in 1.0.0 2.3.4 12.0.1 08.0.0; do
        write_summary "$version"
        rm -rf "$OUT"
        run "$SCRIPT" "$OUT" "$TMP/latest.json" --strict-from-summary
        [ "$status" -eq 1 ]
        [[ "$output" == *"--strict: a placeholder is left in privacy/index.html"* ]] || return 1
        [ ! -e "$OUT" ]
    done
}

@test "a truncated latest.json is refused as invalid JSON" {
    write_summary 0.1.0
    head -c 150 "$TMP/latest.json" > "$TMP/cut.json"
    printf '"schema":1 "version":"0.1.0" "sha256":"%s" "url":"https://x/RoomForMac.dmg"\n' "$SHA_256" >> "$TMP/cut.json"
    run "$SCRIPT" "$OUT" "$TMP/cut.json"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not valid JSON"* ]] || return 1
    [ ! -e "$OUT" ]
}

@test "a symlink in site/ fails" {
    make_fixture
    ln -s index.html "$FIXTURE/site/alias.html"
    run "$FIXTURE/scripts/stage-site.sh" "$OUT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"site/alias.html is a symlink"* ]] || return 1
    [ ! -e "$OUT" ]
}

@test "a missing page fails, and every missing one is named" {
    make_fixture
    rm "$FIXTURE/site/privacy/index.html" "$FIXTURE/site/404.html"
    run "$FIXTURE/scripts/stage-site.sh" "$OUT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"missing page or asset: site/privacy/index.html"* ]] || return 1
    [[ "$output" == *"missing page or asset: site/404.html"* ]] || return 1
    [ ! -e "$OUT" ]
}

@test "a token that no value is defined for fails" {
    make_fixture
    printf '<p>@RFM_NOPE@</p>\n' >> "$FIXTURE/site/index.html"
    run "$FIXTURE/scripts/stage-site.sh" "$OUT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"error: a token is left over in index.html"* ]] || return 1
    [ ! -e "$OUT" ]
}

@test "broken, root-relative, insecure and anchorless links fail" {
    make_fixture
    {
        printf '<a href="missing/">gone</a>\n'
        printf '<a href="/open-anyway/">root</a>\n'
        printf '<a href="http://example.test/">insecure</a>\n'
        printf '<a href="open-anyway/#nowhere">anchor</a>\n'
        printf '<a href="../../outside/">outside</a>\n'
        printf '<a href="#nowhere-either">same page</a>\n'
        printf '<a href="open-anyway/#safe">fine</a>\n'
        printf '<a href="privacy/">fine</a>\n'
    } >> "$FIXTURE/site/index.html"
    run "$FIXTURE/scripts/stage-site.sh" "$OUT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"index.html: broken link missing/"* ]] || return 1
    [[ "$output" == *"index.html: /open-anyway/ starts with '/'"* ]] || return 1
    [[ "$output" == *"index.html: http://example.test/ is not https"* ]] || return 1
    [[ "$output" == *"index.html: open-anyway/#nowhere points at an id that open-anyway/index.html does not have"* ]] || return 1
    [[ "$output" == *"index.html: ../../outside/ leaves the site"* ]] || return 1
    [[ "$output" == *"index.html: #nowhere-either points at an id that index.html does not have"* ]] || return 1
    [[ "$output" == *"(6 problems)"* ]] || return 1
    [ ! -e "$OUT" ]
}

@test "the real site has no broken link, and the 404 page reaches every page by its full URL" {
    stage_real
    grep -qF "href=\"$SITE_URL/\"" "$OUT/404.html"
    grep -qF "href=\"$SITE_URL/assets/site.css\"" "$OUT/404.html"
    grep -qF 'href="../assets/site.css"' "$OUT/privacy/index.html"
    grep -qF 'href="assets/site.css"' "$OUT/index.html"
}

@test "every staged page is locked down by its Content-Security-Policy and loads nothing from elsewhere" {
    local page file tag target checked=0
    stage_real
    for page in index.html open-anyway/index.html thanks/index.html privacy/index.html 404.html; do
        # The policy comes before anything the page could load.
        run sed -n -e '/<link/q' -e '/<script/q' -e p "$OUT/$page"
        [[ "$output" == *"<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'self'; base-uri 'none'; form-action 'none'\">"* ]] || return 1
        grep -qF '<meta name="viewport" content="width=device-width, initial-scale=1">' "$OUT/$page"
        grep -qF '<meta name="referrer" content="no-referrer">' "$OUT/$page"
        grep -qF '<html lang="en">' "$OUT/$page"
        # A script has a source of its own; no other element carries code or style.
        run grep -o '<script[^>]*>' "$OUT/$page"
        if [ -n "$output" ]; then
            run grep -vc ' src="' <<< "$output"
            [ "$output" = "0" ]
        fi
        run grep -E '<style|<[^>]* (on[a-z]+|style)=' "$OUT/$page"
        [ "$status" -eq 1 ]
        # Scripts, stylesheets and images come from this site, and only from it.
        while IFS= read -r tag; do
            target="${tag#*\"}"
            target="${target%\"}"
            case "$target" in
                http*) [[ "$target" == "$SITE_URL/"* ]] || return 1 ;;
            esac
            checked=$((checked + 1))
        done < <(grep -o -E '<(script|img)[^>]* src="[^"]*"|<link[^>]* href="[^"]*"' "$OUT/$page" | grep -o -E '(src|href)="[^"]*"')
    done
    [ "$checked" -ge 5 ]
    while IFS= read -r file; do
        run grep -nE 'http://|<script src="http|<link href="http|@import|url\(http|url\(//' "$file"
        [ "$status" -eq 1 ]
    done < <(staged_text_files)
}

@test "no page or script sets a cookie, stores anything or sends anything but the one latest.json request" {
    local script
    for script in "$REPO"/site/assets/*.js; do
        run grep -nE 'document\.cookie|localStorage|sessionStorage|indexedDB|sendBeacon|XMLHttpRequest|WebSocket|EventSource|eval\(|new Function|innerHTML|document\.write' "$script"
        [ "$status" -eq 1 ]
    done
    run grep -c 'fetch(' "$REPO/site/assets/thanks.js"
    [ "$output" = "0" ]
    run grep -n 'fetch(' "$REPO/site/assets/download.js"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "1" ]
    [[ "$output" == *"fetch('latest.json'"* ]] || return 1
}

@test "no page names the engine or another cleaner, or tells anyone to use Terminal commands" {
    stage_real
    run grep -rIniwE 'mole|cleanmymac|clean my mac' "$OUT" "$REPO/site"
    [ "$status" -eq 1 ]
    run grep -rIniwE 'xattr|spctl|sudo|chmod|quarantine' "$OUT"
    [ "$status" -eq 1 ]
    run grep -rIl 'Terminal' "$OUT"
    [ "$output" = "$OUT/open-anyway/index.html" ]
}

@test "the privacy page says the checkout reference reaches GitHub Pages" {
    grep -qF 'part of the address your browser requests from GitHub Pages' "$REPO/site/privacy/index.html"
    run grep -c 'is not sent anywhere' "$REPO/site/privacy/index.html"
    [ "$output" = "0" ]
}

@test "the download button is a plain link, and the checksum block starts hidden" {
    grep -qF '<a class="button" href="@RFM_DMG_URL@">Download for Mac</a>' "$REPO/site/index.html"
    grep -qF 'macOS 26 Tahoe or later · Apple silicon and Intel' "$REPO/site/index.html"
    grep -qF '<p class="muted small" id="download-details" hidden>' "$REPO/site/index.html"
    grep -qF 'href="open-anyway/">Read the Open Anyway guide</a>' "$REPO/site/index.html"
    grep -qF 'GPL-3.0' "$REPO/site/index.html"
    run grep -c 'href="https://github.com/@RFM_REPOSITORY@"' "$REPO/site/index.html"
    [ "$output" -ge 2 ]
}

@test "open-anyway/ has every macOS string exactly, and the deep link with its manual path" {
    local page="$TMP/open-anyway.txt" text
    stage_real
    # The page writes "&" as "&amp;". Compare the text a reader sees.
    sed 's/&amp;/\&/g' "$OUT/open-anyway/index.html" > "$page"
    # shellcheck disable=SC1112 # the typographic quotes are the pages' text, not shell quotes
    for text in \
        '“RoomForMac” Not Opened' \
        'Apple could not verify “RoomForMac” is free of malware that may harm your Mac or compromise your privacy.' \
        'Done' \
        'Move to Trash' \
        '“RoomForMac” was blocked to protect your Mac.' \
        'Open Anyway' \
        'Open “RoomForMac”?' \
        'Apple is not able to verify that it is free from malware that could harm your Mac or compromise your privacy. Don’t open this unless you are certain it is from a trustworthy source.' \
        'Privacy & Security' \
        'You are attempting to open an app that may cause harm to your Mac or compromise your privacy' \
        '“RoomForMac” is damaged and can’t be opened.' \
        'href="x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Security">Open Privacy & Security</a>' \
        'Or by hand: Apple menu → System Settings → Privacy & Security → Security.' \
        'Is this safe?' \
        'We never ask you to paste commands into Terminal' \
        'There is no Open Anyway button' \
        'Do step 1 again' \
        'Delete it and <a href="../">download RoomForMac again</a>.' \
        'Drag it from the disk image to Applications'; do
        grep -qF -- "$text" "$page" || {
            echo "missing from open-anyway/: $text" >&2
            return 1
        }
    done
    run grep -c '<li class="step">' "$page"
    [ "$output" = "3" ]
}

@test "each step draws a dialog whose target button pulses, with an outline for reduced motion" {
    local css="$REPO/site/assets/site.css"
    run grep -c 'class="mock-button target"' "$REPO/site/open-anyway/index.html"
    [ "$output" = "3" ]
    run grep -c 'role="img" aria-label="Drawing of' "$REPO/site/open-anyway/index.html"
    [ "$output" = "3" ]
    # The outline is unconditional; the animation is inside the no-preference query.
    run sed -n '/^\.mock \.target {/,/^}/p' "$css"
    [[ "$output" == *"outline: 3px solid var(--action);"* ]] || return 1
    run sed -n '/@media (prefers-reduced-motion: no-preference) {/,/^}/p' "$css"
    [[ "$output" == *"animation: pulse"* ]] || return 1
    run grep -c 'animation:' "$css"
    [ "$output" = "1" ]
}

@test "the style sheet carries the spec's light and dark color tokens and both media queries" {
    local css="$REPO/site/assets/site.css" hex
    for hex in F1F0E5 FCFBF2 333B2D 586440 ADB591 B3915D A8563F 1C2119 262D22 7E8866 C9A877 C97A5F; do
        grep -qi "#$hex" "$css" || {
            echo "site.css lacks the token #$hex" >&2
            return 1
        }
    done
    grep -qF '@media (prefers-color-scheme: dark)' "$css"
    grep -qF '@media (prefers-reduced-motion: no-preference)' "$css"
    grep -qF 'color-scheme: light dark;' "$css"
}

@test "thanks/ is noindex, sends no referrer and never shows an id or a key" {
    local page="$REPO/site/thanks/index.html"
    grep -qF '<meta name="robots" content="noindex">' "$page"
    grep -qF '<meta name="referrer" content="no-referrer">' "$page"
    grep -qF '<script src="../assets/thanks.js" defer></script>' "$page"
    grep -qF 'id="open-app" hidden>Open RoomForMac</a>' "$page"
    # shellcheck disable=SC1112 # a typographic apostrophe of the page, not a shell quote
    grep -qF 'If RoomForMac doesn’t open, open it yourself' "$page"
    run grep -niE 'checkout|license key|licence|order' "$page"
    [ "$status" -eq 1 ]
    grep -qF '}, 600);' "$REPO/site/assets/thanks.js"
    run grep -c 'setTimeout' "$REPO/site/assets/thanks.js"
    [ "$output" = "1" ]
    grep -qF '<meta name="robots" content="noindex">' "$REPO/site/404.html"
}

@test "thanks.js names the same link as DeepLink.swift" {
    local swift="$REPO/RoomForMac/App/DeepLink.swift" js="$REPO/site/assets/thanks.js"
    [ "$(sed -n 's/.*static let scheme = "\(.*\)"/\1/p' "$swift")" = "$(sed -n "s/^var ROOMFORMAC_LINK_SCHEME = '\(.*\)';/\1/p" "$js")" ]
    [ "$(sed -n 's/.*components.host?.lowercased() == "\(.*\)",/\1/p' "$swift")" = "$(sed -n "s/^var ROOMFORMAC_LINK_HOST = '\(.*\)';/\1/p" "$js")" ]
    [ "$(sed -n 's/.*item.name == "\(.*\)",/\1/p' "$swift")" = "$(sed -n "s/^var ROOMFORMAC_LINK_PARAMETER = '\(.*\)';/\1/p" "$js")" ]
    [ "$(sed -n 's/.*static let maxCheckoutIDLength = \([0-9]*\)/\1/p' "$swift")" = "$(sed -n 's/^var ROOMFORMAC_CHECKOUT_ID_MAX = \([0-9]*\);/\1/p' "$js")" ]
    # None of the four came back empty, which would make the comparisons above vacuous.
    [ "$(sed -n 's/.*static let scheme = "\(.*\)"/\1/p' "$swift")" = "roomformac" ]
    [ "$(sed -n 's/.*static let maxCheckoutIDLength = \([0-9]*\)/\1/p' "$swift")" = "128" ]
}

@test "roomForMacDeepLink turns a checkout id into the link that opens the app" {
    local longest
    longest="$(printf '%0128d' 0)"
    deep_links '?checkout_id=123e4567-e89b-12d3-a456-426614174000' \
        '?checkout_id=abc_DEF-123' \
        '?checkout_id=x' \
        "?checkout_id=$longest"
    [ "$status" -eq 0 ]
    [ "$output" = "roomformac://purchased?checkout_id=123e4567-e89b-12d3-a456-426614174000
roomformac://purchased?checkout_id=abc_DEF-123
roomformac://purchased?checkout_id=x
roomformac://purchased?checkout_id=$longest" ]
}

@test "roomForMacDeepLink refuses everything DeepLink.parse refuses, and more" {
    local too_long expected="" count=0
    too_long="$(printf '%0129d' 0)"
    local inputs=(
        ''
        '?'
        '?checkout_id='
        '@undefined'
        "?checkout_id=$too_long"
        '?checkout_id="><script>'
        '?checkout_id=a&b'
        '?checkout_id=a%26b'
        '?checkout_id=%41bc'
        '?checkout_id=a&checkout_id=b'
        '?checkout_id=a&other=b'
        '?other=a&checkout_id=a'
        '?other=a'
        '?checkout_id'
        'checkout_id=abc'
        '?CHECKOUT_ID=abc'
        '?checkout_id=abc&'
        $'?checkout_id=abc\n'
        '?checkout_id=a b'
        '?checkout_id=a+b'
        '?checkout_id=a;b'
        '?checkout_id=é'
        '??checkout_id=abc'
        '?checkout_id=abc#top'
    )
    for _ in "${inputs[@]}"; do
        expected="${expected}${expected:+$'\n'}null"
        count=$((count + 1))
    done
    deep_links "${inputs[@]}"
    [ "$status" -eq 0 ]
    [ "$output" = "$expected" ]
    [ "$count" -eq 24 ]
}

@test "roomForMacDownloadDetails shows a release summary's version, size and checksum" {
    download_details \
        '{"schema":1,"version":"0.1.0","dmg":{"size":11840000,"sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}}' \
        '{"schema":1,"version":"12.34.56","build":12034056,"dmg":{"url":"https://example.test/x","size":123456789,"sha256":"fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"}}'
    [ "$status" -eq 0 ]
    [ "$output" = '{"version":"0.1.0","megabytes":"11.8","sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}
{"version":"12.34.56","megabytes":"123.5","sha256":"fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"}' ]
}

@test "roomForMacDownloadDetails refuses anything that is not a complete release summary" {
    local good_sha="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" expected=""
    local inputs=(
        'null'
        '[]'
        'not json'
        '{"schema":2,"version":"0.1.0","dmg":{"size":1,"sha256":"'"$good_sha"'"}}'
        '{"schema":1,"version":"v0.1.0","dmg":{"size":1,"sha256":"'"$good_sha"'"}}'
        '{"schema":1,"version":"0.1","dmg":{"size":1,"sha256":"'"$good_sha"'"}}'
        '{"schema":1,"version":"0.1.0"}'
        '{"schema":1,"version":"0.1.0","dmg":null}'
        '{"schema":1,"version":"0.1.0","dmg":{"size":0,"sha256":"'"$good_sha"'"}}'
        '{"schema":1,"version":"0.1.0","dmg":{"size":"11840000","sha256":"'"$good_sha"'"}}'
        '{"schema":1,"version":"0.1.0","dmg":{"size":1.5,"sha256":"'"$good_sha"'"}}'
        '{"schema":1,"version":"0.1.0","dmg":{"size":1,"sha256":"0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"}}'
        '{"schema":1,"version":"0.1.0","dmg":{"size":1,"sha256":"<img src=x>"}}'
        '{"schema":1,"version":"0.1.0","dmg":{"size":1,"sha256":"0123456789abcdef"}}'
        '{"schema":1,"version":"<b>0.1.0</b>","dmg":{"size":1,"sha256":"'"$good_sha"'"}}'
    )
    for _ in "${inputs[@]}"; do
        expected="${expected}${expected:+$'\n'}null"
    done
    download_details "${inputs[@]}"
    [ "$status" -eq 0 ]
    [ "$output" = "$expected" ]
    [ "${#inputs[@]}" -eq 15 ]
}

@test "stage-site.sh uses only what bash 3.2, macOS and ubuntu-latest share" {
    # Comments may name what the script avoids; only its code counts.
    run bash -c 'sed "s/^[[:space:]]*#.*//" "$1" | grep -nE "sed -i|readlink -f|grep -[a-zA-Z]*P|mapfile|readarray|declare -A|[$][{][A-Za-z_]+(,,|\^\^)|gsed|ggrep|realpath"' _ "$REPO/scripts/stage-site.sh"
    [ "$status" -eq 1 ]
    [ "$(sed -n 1p "$REPO/scripts/stage-site.sh")" = "#!/bin/bash" ]
    /bin/bash -n "$REPO/scripts/stage-site.sh"
}
