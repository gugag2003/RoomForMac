#!/bin/bash
# Stage the RoomForMac site for GitHub Pages: copy site/ to a folder, fill in the
# @RFM_…@ tokens from Config/Distribution.xcconfig, and check the result.
#
# Runs on macOS and on ubuntu-latest (release.yml's `pages` job and pages.yml),
# so it uses only bash 3.2 and POSIX tools: no `sed -i`, no `grep -P`, no
# `readlink -f`. Nothing is written to <out-dir> unless every check passed.
#
# Tokens (replaced in *.html and *.js):
#   @RFM_REPOSITORY@  owner/name, from RFM_REPOSITORY
#   @RFM_SITE_URL@    RFM_SITE_URL without a trailing slash
#   @RFM_DMG_URL@     https://github.com/<repository>/releases/latest/download/RoomForMac.dmg
#   @RFM_FEED_URL@    RFM_FEED_URL
# The appcast is never part of the site: it is a release asset (Plan 6, Ruling 3).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SITE="$ROOT/site"
REQUIRED_FILES="index.html open-anyway/index.html thanks/index.html privacy/index.html 404.html assets/site.css assets/download.js assets/thanks.js"

# shellcheck source=lib/distribution.sh
source "$ROOT/scripts/lib/distribution.sh"

usage() {
    cat << 'EOF'
Usage: scripts/stage-site.sh <out-dir> [latest.json] [--strict | --strict-from-summary]

Copies site/ to <out-dir>, fills in the @RFM_…@ tokens from
Config/Distribution.xcconfig, and copies latest.json when one is given.
Fails on a missing page, a symlink, a token left over, a broken link, or
appcast.xml in site/. <out-dir> must not exist or must be empty.

  --strict               also fail on any "[OWNER:" placeholder (required from v1.0.0)
  --strict-from-summary  --strict when latest.json's version is 1.0.0 or later
                         (needs latest.json; used by pages.yml)

Exit status: 0 staged; 1 a check failed (every problem is printed, and
<out-dir> is left alone); 2 bad usage or a refused <out-dir>.
EOF
}

usage_error() {
    printf 'error: %s\n' "$*" >&2
    printf 'Run scripts/stage-site.sh --help for usage.\n' >&2
    exit 2
}

failures=0
fail() {
    printf 'error: %s\n' "$*" >&2
    failures=$((failures + 1))
}

OUT=""
SUMMARY=""
STRICT=0
STRICT_FROM_SUMMARY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help | -h)
            usage
            exit 0
            ;;
        --strict) STRICT=1 ;;
        --strict-from-summary) STRICT_FROM_SUMMARY=1 ;;
        -*) usage_error "unknown argument: $1" ;;
        *)
            if [[ -z "$OUT" ]]; then
                OUT="$1"
            elif [[ -z "$SUMMARY" ]]; then
                SUMMARY="$1"
            else
                usage_error "unexpected argument: $1"
            fi
            ;;
    esac
    shift
done
[[ -n "$OUT" ]] || usage_error "an output folder is required"
if [[ "$STRICT_FROM_SUMMARY" -eq 1 && -z "$SUMMARY" ]]; then
    usage_error "--strict-from-summary needs a latest.json"
fi

# The output folder: never inside site/ (checked as written), never a folder that has files.
case "$OUT" in
    /*) out_path="$OUT" ;;
    *) out_path="$PWD/$OUT" ;;
esac
case "$out_path/" in
    "$SITE"/*) usage_error "the output folder must not be inside site/" ;;
esac
if [[ -e "$OUT" ]]; then
    [[ -d "$OUT" ]] || usage_error "$OUT exists and is not a folder"
    if [[ -n "$(ls -A "$OUT")" ]]; then
        usage_error "$OUT is not empty; remove it first"
    fi
fi

# Values the pages get. They end up inside HTML and JavaScript, so each must
# match a strict pattern: no quote, angle bracket, backslash, ampersand or `|`.
repository="$(distribution_value "$ROOT" RFM_REPOSITORY)"
site_url="$(distribution_value "$ROOT" RFM_SITE_URL)"
feed_url="$(distribution_value "$ROOT" RFM_FEED_URL)"
site_url="${site_url%/}"
dmg_url="https://github.com/$repository/releases/latest/download/RoomForMac.dmg"
repository_pattern='^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'
site_pattern='^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$'
feed_pattern='^https://[A-Za-z0-9._~:/?=%+-]+$'
[[ "$repository" =~ $repository_pattern ]] || usage_error "RFM_REPOSITORY must look like owner/name, not '$repository'"
[[ "$site_url" =~ $site_pattern ]] || usage_error "RFM_SITE_URL must be an https URL, not '$site_url'"
[[ "$feed_url" =~ $feed_pattern ]] || usage_error "RFM_FEED_URL must be an https URL, not '$feed_url'"

# The source tree.
[[ -d "$SITE" ]] || usage_error "site/ is missing"
while IFS= read -r link; do
    fail "site/${link#"$SITE"/} is a symlink; Pages refuses symlinks in the artifact"
done < <(find "$SITE" -type l)
for required in $REQUIRED_FILES; do
    if [[ ! -f "$SITE/$required" ]]; then
        fail "missing page or asset: site/$required"
    fi
done
if [[ -e "$SITE/appcast.xml" ]]; then
    fail "site/appcast.xml must not exist: the appcast is a release asset, never part of the site"
fi
if [[ "$failures" -gt 0 ]]; then
    exit 1
fi

TMPDIR="${TMPDIR:-/tmp}"
TMPDIR="${TMPDIR%/}"
tmp="$(mktemp -d "$TMPDIR/rfm-site.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

cp -R "$SITE"/. "$tmp"/
find "$tmp" -name .DS_Store -type f -exec rm -f {} +

# Fill in the tokens, without `sed -i`.
while IFS= read -r file; do
    LC_ALL=C sed \
        -e "s|@RFM_REPOSITORY@|$repository|g" \
        -e "s|@RFM_SITE_URL@|$site_url|g" \
        -e "s|@RFM_DMG_URL@|$dmg_url|g" \
        -e "s|@RFM_FEED_URL@|$feed_url|g" \
        "$file" > "$file.rfm-tmp"
    mv "$file.rfm-tmp" "$file"
done < <(find "$tmp" -type f \( -name '*.html' -o -name '*.js' \))
while IFS= read -r line; do
    fail "a token is left over in ${line#"$tmp"/}"
done < <(grep -rIn '@RFM_' "$tmp" || true)

# latest.json: the release summary of Task 11, copied as it is once it looks right.
strict="$STRICT"
if [[ -n "$SUMMARY" ]]; then
    if [[ ! -f "$SUMMARY" ]]; then
        fail "latest.json not found: $SUMMARY"
    else
        space='[[:space:]]*'
        if ! python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$SUMMARY" > /dev/null 2>&1; then
            fail "$SUMMARY is not a release summary: not valid JSON"
        fi
        grep -Eq "\"schema\"$space:${space}1[,}[:space:]]" "$SUMMARY" || fail "$SUMMARY is not a release summary: schema 1 is missing"
        grep -Eq "\"version\"$space:$space\"[0-9]+\.[0-9]+\.[0-9]+\"" "$SUMMARY" || fail "$SUMMARY is not a release summary: no X.Y.Z version"
        grep -Eq "\"sha256\"$space:$space\"[0-9a-f]{64}\"" "$SUMMARY" || fail "$SUMMARY is not a release summary: no SHA-256"
        grep -Eq "\"url\"$space:$space\"https://[^\"]+/RoomForMac\\.dmg\"" "$SUMMARY" || fail "$SUMMARY is not a release summary: no RoomForMac.dmg url"
        cp "$SUMMARY" "$tmp/latest.json"
        if [[ "$STRICT_FROM_SUMMARY" -eq 1 ]]; then
            major="$(sed -n "s/.*\"version\"$space:$space\"\\([0-9][0-9]*\\)\\.[0-9][0-9]*\\.[0-9][0-9]*\".*/\\1/p" "$SUMMARY" | head -n 1)"
            if [[ "$major" =~ ^[0-9]+$ ]] && [[ "$((10#$major))" -ge 1 ]]; then
                strict=1
            fi
        fi
    fi
fi
if [[ "$strict" -eq 1 ]]; then
    while IFS= read -r line; do
        fail "--strict: a placeholder is left in ${line#"$tmp"/}"
    done < <(grep -rIn '\[OWNER:' "$tmp" || true)
fi

# Links. Relative links must reach a file (and an id) in the staged tree; links
# built from the site URL are mapped to the tree; other https links are not followed.
# A link that starts with "/" would break under https://<user>.github.io/<repo>/.
normalize() {
    local IFS=/ part result=""
    set -f
    for part in $1; do
        case "$part" in
            "" | .) ;;
            ..)
                if [[ "$result" == */* ]]; then
                    result="${result%/*}"
                elif [[ -n "$result" ]]; then
                    result=""
                else
                    set +f
                    return 1
                fi
                ;;
            *) result="${result:+$result/}$part" ;;
        esac
    done
    set +f
    printf '%s' "$result"
}

check_link() {
    local rel="$1" ref="$2" base="" mapped=0 path fragment target
    case "$ref" in
        "" | mailto:* | tel:* | roomformac:* | x-apple.systempreferences:*) return 0 ;;
        http://*)
            fail "$rel: $ref is not https"
            return 0
            ;;
        //*)
            fail "$rel: $ref is a protocol-relative link"
            return 0
            ;;
        "$site_url" | "$site_url"/* | "$site_url"\?* | "$site_url"\#*)
            ref="${ref#"$site_url"}"
            mapped=1
            ;;
        https://*) return 0 ;;
        /*)
            fail "$rel: $ref starts with '/', which breaks under a project site path"
            return 0
            ;;
        [A-Za-z]*:*)
            fail "$rel: $ref uses a scheme the site does not allow"
            return 0
            ;;
        *)
            base="$(dirname "$rel")"
            if [[ "$base" == "." ]]; then
                base=""
            fi
            ;;
    esac
    fragment=""
    if [[ "$ref" == *"#"* ]]; then
        fragment="${ref#*#}"
    fi
    path="${ref%%#*}"
    path="${path%%\?*}"
    if [[ -z "$path" && "$mapped" -eq 0 ]]; then
        target="$rel" # "#id" or "?query": this page
    else
        case "$path" in
            /*) path="${path#/}" ;;
            *) path="${base:+$base/}$path" ;;
        esac
        if ! target="$(normalize "$path")"; then
            fail "$rel: $ref leaves the site"
            return 0
        fi
        if [[ -z "$target" || -d "$tmp/$target" ]]; then
            target="${target:+$target/}index.html"
        fi
        if [[ ! -f "$tmp/$target" ]]; then
            fail "$rel: broken link $ref"
            return 0
        fi
    fi
    if [[ -n "$fragment" ]]; then
        if [[ ! "$fragment" =~ ^[A-Za-z0-9_-]+$ ]]; then
            fail "$rel: $ref has an unusual fragment"
        elif ! grep -q "id=\"$fragment\"" "$tmp/$target"; then
            fail "$rel: $ref points at an id that $target does not have"
        fi
    fi
}

while IFS= read -r page; do
    rel="${page#"$tmp"/}"
    while IFS= read -r ref; do
        check_link "$rel" "$ref"
    done < <(grep -o -E '(href|src)="[^"]*"' "$page" | sed -e 's/^[a-z]*="//' -e 's/"$//' || true)
done < <(find "$tmp" -type f -name '*.html')

if [[ "$failures" -gt 0 ]]; then
    printf 'error: the site was not staged (%d problems)\n' "$failures" >&2
    exit 1
fi

mkdir -p "$OUT"
cp -R "$tmp"/. "$OUT"/
count="$(find "$OUT" -type f | wc -l | tr -d ' ')"
printf 'staged %s files into %s (%s, %s)\n' "$count" "$OUT" "$site_url" "$repository"
